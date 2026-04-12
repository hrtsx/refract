# frozen_string_literal: true

require "json"
require "open3"

class LspClient
  def initialize(name, cmd, root:)
    @name = name
    @cmd = cmd
    @root = File.expand_path(root)
    @next_id = 0
    @notifs = []
    @rss_peak_kb = 0
    @rss_thread = nil
    @stop_rss = false
  end

  attr_reader :rss_peak_kb

  def start
    @stdin, @stdout, @stderr, @wait = Open3.popen3(*@cmd)
    @stdin.binmode
    @stdout.binmode
    @pid = @wait.pid
    start_rss_sampler
  end

  def stop
    @stop_rss = true
    @rss_thread&.join(1)
    begin
      send_notify("exit", nil)
    rescue StandardError
    end
    Process.kill("TERM", @pid) rescue nil
    sleep 0.05
    Process.kill("KILL", @pid) rescue nil
    @stdin.close rescue nil
    @stdout.close rescue nil
    @stderr.close rescue nil
  end

  def request(method, params, timeout: 30)
    id = (@next_id += 1)
    write({ jsonrpc: "2.0", id: id, method: method, params: params })
    deadline = monotonic + timeout
    while monotonic < deadline
      msg = read_msg(deadline - monotonic)
      next unless msg
      if msg["id"] == id
        return msg
      else
        @notifs << msg
      end
    end
    nil
  end

  def send_notify(method, params)
    write({ jsonrpc: "2.0", method: method, params: params })
  end

  def initialize!
    request("initialize", {
      processId: Process.pid,
      rootUri: "file://#{@root}",
      workspaceFolders: [{ uri: "file://#{@root}", name: File.basename(@root) }],
      capabilities: {
        textDocument: {
          synchronization: { didSave: true, willSave: false },
          definition: { dynamicRegistration: false, linkSupport: false },
          hover: { dynamicRegistration: false, contentFormat: ["markdown", "plaintext"] },
          completion: { dynamicRegistration: false, completionItem: { snippetSupport: false } },
        },
        workspace: { workspaceFolders: true, configuration: false },
      },
      initializationOptions: {},
    }, timeout: 60)
    send_notify("initialized", {})
  end

  def did_open(path, text)
    uri = "file://#{File.expand_path(path)}"
    send_notify("textDocument/didOpen", {
      textDocument: { uri: uri, languageId: "ruby", version: 1, text: text },
    })
    uri
  end

  def definition(uri, line, char, timeout: 30)
    request("textDocument/definition", {
      textDocument: { uri: uri },
      position: { line: line, character: char },
    }, timeout: timeout)
  end

  def hover(uri, line, char, timeout: 15)
    request("textDocument/hover", {
      textDocument: { uri: uri },
      position: { line: line, character: char },
    }, timeout: timeout)
  end

  def completion(uri, line, char, timeout: 15)
    request("textDocument/completion", {
      textDocument: { uri: uri },
      position: { line: line, character: char },
    }, timeout: timeout)
  end

  def references(uri, line, char, timeout: 15)
    request("textDocument/references", {
      textDocument: { uri: uri },
      position: { line: line, character: char },
      context: { includeDeclaration: true },
    }, timeout: timeout)
  end

  def document_symbol(uri, timeout: 15)
    request("textDocument/documentSymbol", {
      textDocument: { uri: uri },
    }, timeout: timeout)
  end

  def workspace_symbol(query, timeout: 15)
    request("workspace/symbol", { query: query }, timeout: timeout)
  end

  def rename(uri, line, char, new_name, timeout: 15)
    request("textDocument/rename", {
      textDocument: { uri: uri },
      position: { line: line, character: char },
      newName: new_name,
    }, timeout: timeout)
  end

  def did_save(uri, text)
    send_notify("textDocument/didSave", {
      textDocument: { uri: uri },
      text: text,
    })
  end

  def did_change(uri, text)
    @doc_versions ||= Hash.new(1)
    @doc_versions[uri] += 1
    send_notify("textDocument/didChange", {
      textDocument: { uri: uri, version: @doc_versions[uri] },
      contentChanges: [{ text: text }],
    })
  end

  def wait_for_diagnostics(uri:, started_at:, settle_ms: 600, hard_timeout: 12)
    deadline = started_at + hard_timeout
    settle_window = settle_ms / 1000.0
    first_ms = nil
    last_msg_at = nil
    received = 0
    loop do
      remaining = deadline - monotonic
      break if remaining <= 0
      timeout = if last_msg_at
                  [settle_window - (monotonic - last_msg_at), 0.05].max
                else
                  remaining
                end
      msg = read_msg(timeout)
      if msg.nil?
        break if last_msg_at && (monotonic - last_msg_at) >= settle_window
        next
      end
      next unless msg.is_a?(Hash) && msg["method"] == "textDocument/publishDiagnostics"
      next unless msg.dig("params", "uri") == uri
      first_ms ||= ((monotonic - started_at) * 1000).round(2)
      last_msg_at = monotonic
      received += 1
    end
    settle_ms_val = last_msg_at ? ((last_msg_at - started_at) * 1000).round(2) : nil
    { first_ms: first_ms, settle_ms: settle_ms_val, received_count: received }
  end

  def write_dead?
    @stdin.nil? || @stdin.closed?
  end

  private

  def write(obj)
    body = JSON.dump(obj)
    @stdin.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
    @stdin.flush
  end

  def read_msg(timeout)
    return nil if timeout <= 0
    deadline = monotonic + timeout
    headers = +""
    until headers.end_with?("\r\n\r\n")
      remaining = deadline - monotonic
      break if remaining <= 0
      ready = IO.select([@stdout], nil, nil, remaining)
      return nil unless ready
      ch = @stdout.read(1)
      return nil if ch.nil?
      headers << ch
    end
    return nil if headers.empty?
    if (m = headers.match(/Content-Length: (\d+)/i))
      len = m[1].to_i
      body = +""
      while body.bytesize < len
        chunk = @stdout.read(len - body.bytesize)
        break if chunk.nil?
        body << chunk
      end
      JSON.parse(body)
    end
  rescue StandardError
    nil
  end

  def start_rss_sampler
    @rss_thread = Thread.new do
      while !@stop_rss
        begin
          line = File.read("/proc/#{@pid}/status").lines.find { |l| l.start_with?("VmRSS:") }
          if line && (m = line.match(/(\d+)\s*kB/))
            kb = m[1].to_i
            @rss_peak_kb = kb if kb > @rss_peak_kb
          end
        rescue StandardError
        end
        sleep 0.02
      end
    end
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

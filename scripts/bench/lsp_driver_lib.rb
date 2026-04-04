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

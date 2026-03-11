import {
  ExtensionContext,
  StatusBarAlignment,
  commands,
  window,
  workspace,
} from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

type ProgressValue =
  | { kind: "begin"; title: string; message?: string }
  | { kind: "report"; message?: string; percentage?: number }
  | { kind: "end"; message?: string };

export async function activate(context: ExtensionContext) {
  const config = workspace.getConfiguration("refract");
  const command = config.get<string>("path", "refract");

  const serverOptions: ServerOptions = {
    run:   { command, args: [], transport: TransportKind.stdio },
    debug: { command, args: [], transport: TransportKind.stdio },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { scheme: "file", language: "ruby" },
      { scheme: "file", language: "erb" },
      { scheme: "file", language: "haml" },
      { scheme: "file", language: "slim" },
      { scheme: "file", pattern: "**/*.rake" },
      { scheme: "file", pattern: "**/*.gemspec" },
      { scheme: "file", pattern: "**/Gemfile" },
      { scheme: "file", pattern: "**/Rakefile" },
    ],
    initializationOptions: {
      disableGemIndex:    config.get("disableGemIndex"),
      disableRubocop:     config.get("disableRubocop"),
      maxFileSizeMb:      config.get("maxFileSizeMb"),
      maxWorkers:         config.get("maxWorkers"),
      excludeDirs:        config.get("excludeDirs"),
      logLevel:           config.get("logLevel"),
      rubocopDebounceMs:  config.get("rubocopDebounceMs"),
    },
  };

  context.subscriptions.push(
    workspace.onDidChangeConfiguration(e => {
      if (e.affectsConfiguration("refract")) {
        window.showInformationMessage(
          "Refract: settings changed — reload the window to apply.",
          "Reload Window"
        ).then(selected => {
          if (selected === "Reload Window") {
            commands.executeCommand("workbench.action.reloadWindow");
          }
        });
      }
    })
  );

  // Status bar: shows indexing progress from $/progress notifications
  const bar = window.createStatusBarItem(StatusBarAlignment.Left, 100);
  bar.tooltip = "Refract Ruby LSP";
  context.subscriptions.push(bar);

  let outputChannel: ReturnType<typeof window.createOutputChannel> | undefined;

  function getOutputChannel() {
    if (!outputChannel) {
      outputChannel = window.createOutputChannel("Refract");
      context.subscriptions.push(outputChannel);
    }
    return outputChannel;
  }

  try {
    client = new LanguageClient("refract", "Refract", serverOptions, clientOptions);
    await client.start();
    context.subscriptions.push({ dispose: () => client?.stop() });

    // Show initial "ready" state; will be replaced by $/progress on first index
    bar.text = "$(ruby) Refract";
    bar.show();

    // Live indexing progress via $/progress (begin/report/end)
    client.onNotification("$/progress", (params: { token: string; value: ProgressValue }) => {
      const { value } = params;
      if (value.kind === "begin") {
        bar.text = "$(sync~spin) Refract: indexing…";
        bar.show();
      } else if (value.kind === "report" && value.message) {
        bar.text = `$(sync~spin) Refract: ${value.message}`;
      } else if (value.kind === "end") {
        bar.text = "$(ruby) Refract";
        // Brief "done" flash then settle to idle icon
        setTimeout(() => { bar.text = "$(ruby) Refract"; }, 1500);
      }
    });

    // Commands advertised by the server's executeCommandProvider
    const serverCommands: Array<[string, string]> = [
      ["refract.recheckRubocop",  "refract.recheckRubocop"],
      ["refract.restartIndexer",  "refract.restartIndexer"],
      ["refract.forceReindex",    "refract.forceReindex"],
      ["refract.toggleGemIndex",  "refract.toggleGemIndex"],
      ["refract.showReferences",  "refract.showReferences"],
      ["refract.runTest",         "refract.runTest"],
    ];
    for (const [vscodeCmd, serverCmd] of serverCommands) {
      context.subscriptions.push(
        commands.registerCommand(vscodeCmd, () =>
          client?.sendRequest("workspace/executeCommand", { command: serverCmd })
        )
      );
    }

  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);

    if (msg.includes("ENOENT")) {
      const hint = `'${command}' not found — install refract or set refract.path in settings.`;
      window.showErrorMessage(`Refract: ${hint}`, "Open Settings").then(selected => {
        if (selected === "Open Settings") {
          commands.executeCommand("workbench.action.openSettings", "refract.path");
        }
      });
    } else {
      window.showErrorMessage(`Refract failed to start: ${msg}`, "Show Output").then(selected => {
        if (selected === "Show Output") {
          getOutputChannel().appendLine(msg);
          getOutputChannel().show();
        }
      });
    }
  }
}

export async function deactivate(): Promise<void> {
  await client?.stop();
}

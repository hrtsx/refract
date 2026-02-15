import { ExtensionContext, window, workspace } from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export async function activate(context: ExtensionContext) {
  const config = workspace.getConfiguration("refract");
  const command = config.get<string>("path", "refract");

  const serverOptions: ServerOptions = { command, args: [] };

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
      disableGemIndex: config.get("disableGemIndex"),
      disableRubocop: config.get("disableRubocop"),
      maxFileSizeMb: config.get("maxFileSizeMb"),
      maxWorkers: config.get("maxWorkers"),
      excludeDirs: config.get("excludeDirs"),
      logLevel: config.get("logLevel"),
    },
  };

  try {
    client = new LanguageClient("refract", "Refract", serverOptions, clientOptions);
    await client.start();
    context.subscriptions.push({ dispose: () => client?.stop() });
  } catch (e) {
    window.showErrorMessage(
      `Refract failed to start: ${e instanceof Error ? e.message : e}. ` +
      `Ensure '${command}' is installed and in your PATH.`
    );
  }
}

export async function deactivate(): Promise<void> {
  await client?.stop();
}

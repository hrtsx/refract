import * as assert from 'assert';
import * as vscode from 'vscode';

export async function run(): Promise<void> {
	await vscode.extensions.all;
	const refractExt = vscode.extensions.getExtension('refract.refract');
	assert.ok(refractExt, 'Refract extension not found');
	if (!refractExt.isActive) {
		await refractExt.activate();
	}
	const ext = refractExt.exports;
	assert.ok(ext !== undefined, 'Extension exports should be defined');

	// W5.1: assert progress + status-bar are wired (smoke surface).
	const smoke = (ext as { __smoke?: { hasStatusBar: boolean; hasProgressHandler: boolean; clientStarted: boolean } }).__smoke;
	assert.ok(smoke, 'Extension smoke surface missing');
	assert.strictEqual(smoke.hasStatusBar, true, 'Status bar not wired');
	assert.strictEqual(smoke.hasProgressHandler, true, '$/progress handler not wired');

	console.log('Refract VSCode extension smoke OK');
}

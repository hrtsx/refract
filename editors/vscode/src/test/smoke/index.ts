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
	console.log('Refract VSCode extension smoke OK');
}

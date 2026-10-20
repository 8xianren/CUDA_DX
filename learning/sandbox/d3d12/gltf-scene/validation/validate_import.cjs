// 外部资源入口：官方Validator负责JSON/GLB与二进制规范校验；通过后才启动C++适配器。
// 本脚本不手写GLB解析。Node仅用于现成校验库，渲染与资源适配仍在C++。
const fs = require('node:fs/promises');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const validator = require('gltf-validator');
async function main() {
    const [input, output] = process.argv.slice(2);
    if (!input || !output) throw new Error('usage: node validate_import.cjs input report.json');
    const full = path.resolve(input);
    const bytes = await fs.readFile(full);
    const report = await validator.validateBytes(new Uint8Array(bytes), {
        uri: path.basename(full),
        maxIssues: 100,
        // 未知扩展即使在Validator中仅为警告，课程入口也升级为错误，避免默默忽略。
        severityOverrides: {UNSUPPORTED_EXTENSION: 0},
        externalResourceFunction: uri => fs.readFile(path.resolve(path.dirname(full), decodeURIComponent(uri)))
    });
    await fs.mkdir(path.dirname(path.resolve(output)), {recursive: true});
    await fs.writeFile(output, JSON.stringify(report, null, 2));
    console.log(`validator=${validator.version()} errors=${report.issues.numErrors} warnings=${report.issues.numWarnings}`);
    if (report.issues.numErrors || report.issues.truncated) {
        console.error('REJECTED [validate] ' + full);
        process.exitCode = 1;
        return;
    }
    // glTF核心是本课程当前支持范围；Validator认识扩展不等于渲染器实现了它。
    if (report.info?.extensionsUsed?.length) {
        console.error('REJECTED [scope] extensions deferred: ' + report.info.extensionsUsed.join(', '));
        process.exitCode = 1;
        return;
    }
    if (report.info?.hasSkins || report.info?.hasMorphTargets || report.info?.animationCount) {
        console.error('REJECTED [scope] skin/morph/animation not implemented');
        process.exitCode = 1;
        return;
    }
    const exe = path.resolve(__dirname, '../build/Release/import_scope_test.exe');
    const run = spawnSync(exe, [full], {encoding:'utf8', windowsHide:true, timeout:30000});
    if (run.stdout) process.stdout.write(run.stdout);
    if (run.stderr) process.stderr.write(run.stderr);
    if (run.error || run.signal || run.status === null) throw new Error('CPU importer failed to finish normally');
    process.exitCode = run.status;
}
main().catch(error => {console.error('REJECTED [validation-io] ' + error.message);process.exitCode=1;});

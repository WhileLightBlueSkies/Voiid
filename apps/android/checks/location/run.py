"""Run location model/wire checks using cached Kotlin tools; no Gradle/app build."""
from pathlib import Path
import os
import subprocess
import tempfile

here = Path(__file__).resolve().parent
android = here.parents[1]
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
version = '2.0.21'

def jar(group, artifact, version=None):
    base = cache / group / artifact
    candidates = sorted((base / version if version else base).glob('**/*.jar'))
    if not candidates:
        raise SystemExit(f'Missing cached dependency: {group}:{artifact}. Restore project dependencies first.')
    return str(candidates[-1])

stdlib = jar('org.jetbrains.kotlin', 'kotlin-stdlib', version)
annotations = jar('org.jetbrains', 'annotations')
runtime = [stdlib, annotations,
           jar('org.jetbrains.kotlinx', 'kotlinx-serialization-core-jvm'),
           jar('org.jetbrains.kotlinx', 'kotlinx-serialization-json-jvm')]
compiler = [jar('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', version), stdlib, annotations,
            jar('org.jetbrains.kotlin', 'kotlin-script-runtime', version),
            jar('org.jetbrains.kotlin', 'kotlin-reflect'),
            jar('org.jetbrains.intellij.deps', 'trove4j'),
            jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm')]
plugin = jar('org.jetbrains.kotlin', 'kotlin-serialization-compiler-plugin-embeddable', version)
java = str(Path(os.environ['JAVA_HOME']) / 'bin/java') if os.environ.get('JAVA_HOME') else 'java'
with tempfile.TemporaryDirectory(prefix='voiid-location-models-') as directory:
    subprocess.run([java, '-cp', os.pathsep.join(compiler), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
                    '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-Xplugin=' + plugin,
                    '-classpath', os.pathsep.join(runtime), '-d', directory,
                    str(android / 'app/src/main/java/com/voiid/app/model/LocationModels.kt'),
                    str(here / 'LocationStateCheck.kt')], check=True)
    subprocess.run([java, '-cp', os.pathsep.join([directory] + runtime),
                    'com.voiid.app.model.LocationStateCheckKt'], check=True)

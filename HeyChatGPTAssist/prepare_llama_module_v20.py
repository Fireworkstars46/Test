from pathlib import Path
import runpy

runpy.run_path('prepare_llama_module_v19.py', run_name='__main__')

p = Path('llama.cpp/examples/llama.android/lib/build.gradle.kts')
s = p.read_text()
s = s.replace('arguments += "-DGGML_BACKEND_DL=ON"',
              'arguments += "-DGGML_BACKEND_DL=OFF"')
s = s.replace('arguments += "-DGGML_CPU_ALL_VARIANTS=ON"',
              'arguments += "-DGGML_CPU_ALL_VARIANTS=OFF"')
p.write_text(s)

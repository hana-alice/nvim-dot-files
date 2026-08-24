import json, os
cdb = json.load(open(r'<PROJ_DRIVE>\UEProj\Engine\.clangd-index\test-rsp\compile_commands.json'))
template = None
for e in cdb:
    f = e['file'].replace('\\', '/')
    if '/Renderer/Private/' in f:
        template = e
        break
unity_cpp = r'<PROJ_DRIVE>\UEProj\Engine\Intermediate\Build\Win64\x64\UnrealEditor\Development\Renderer\Module.Renderer.15.cpp'
new_args = list(template['arguments'])
old_cpp = template['file']
for i, a in enumerate(new_args):
    if a == old_cpp or a.endswith(os.path.basename(old_cpp)):
        new_args[i] = unity_cpp
        break
new_entry = {'directory': template['directory'], 'arguments': new_args, 'file': unity_cpp}
out = r'<PROJ_DRIVE>\UEProj\Engine\.clangd-index\test-ue-unity\compile_commands.json'
os.makedirs(os.path.dirname(out), exist_ok=True)
json.dump([new_entry], open(out, 'w'))
print('Wrote 1-entry CDB:', out)

import bpy
import json

scene = bpy.context.scene

outdir = '/home/nc/projects/tankers/resources/anim'

for action in bpy.data.actions:
    r = {}
    #fs = obj.animation_data.action.fcurves
    #keyframes = sorted({p.co[0] for f in fs for p in f.keyframe_points})
    keyframes = list(range(scene.frame_start, scene.frame_end+1))
    r['_keyframes'] = keyframes
    for obj in scene.objects:
        r[obj.name] = []
        for k in keyframes:
            bpy.context.scene.frame_set(int(k))
            r[obj.name].append(tuple(obj.location))
            print(obj.name, int(k), obj.location, sep='\t')
    fname = f'{outdir}/{action.name}.json'
    with open(fname, 'w') as f:
        json.dump(r, f)
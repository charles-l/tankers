import bpy
import json

scene = bpy.context.scene

outdir = '/home/nc/projects/tankers/resources/anim'

for action in bpy.data.actions:
    keyframes = list(range(scene.frame_start, scene.frame_end+1))
    
    markers = []
    marker_i = 0
    current_state = None
    for frame in keyframes:
        if action.pose_markers[marker_i:]:
            if frame == action.pose_markers[marker_i].frame:
                n = action.pose_markers[marker_i].name
                marker_i += 1
                
                if n.startswith('('):
                    current_state = n[1:]
                elif n.startswith(')'):
                    current_state = None
                else: # one off
                    markers.append(n)
                    continue
        markers.append(current_state)
        
    r = {}
    #fs = obj.animation_data.action.fcurves
    #keyframes = sorted({p.co[0] for f in fs for p in f.keyframe_points})
    r['_keyframes'] = keyframes
    r['_events'] = markers
    for obj in scene.objects:
        r[obj.name] = {'pos': [], 'frame': []}
        for k in keyframes:
            bpy.context.scene.frame_set(int(k))
            r[obj.name]['pos'].append(tuple(obj.location))
            if obj.image_user:
                r[obj.name]['frame'].append(obj.image_user.frame_offset)
            
            #print(obj.name, int(k), obj.location, sep='\t')
    fname = f'{outdir}/{action.name}.json'
    with open(fname, 'w') as f:
        json.dump(r, f)
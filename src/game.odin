package main
import rl "raylib"
import "core:c"
import "core:fmt"
import "core:os"
import "core:math"
import "core:math/linalg"
import "core:math/noise"
import "core:encoding/json"

import "core:runtime"
import "core:container/small_array"
import "core:path/filepath"
import "core:strings"

// TODO scenarios:
// tank vs tank (two pendelums)
// tank vs small enemies, lead up to miniboss?
// tank (on helicopter) vs boss


@export
_fltused: c.int = 0

impact_tex: rl.Texture
tank_tex: rl.Texture
sounds: map[string]rl.Sound
animations: []Animation

State :: enum {
    DEFAULT,
    DAMAGE,
}

Animation :: struct {
    name: string,

    pos: []rl.Vector2,
    state: []State,

    tex: []rl.Texture,
    frame: []i32,
}

load_json_array :: proc($T: typeid, arr: json.Array) -> []T {
    r := make([]T, len(arr))
    when T == rl.Vector2 {
        for vec, i in arr {
            x := vec.(json.Array)[0].(json.Float)
            y := vec.(json.Array)[1].(json.Float)
            //z := vec.(json.Array)[2].(json.Float) // unused
            r[i] = rl.Vector2{40 + cast(f32) x * 100, 400 + cast(f32) y * -100}
        }
    } else when T == i32 {
        for v, i in arr {
            r[i] = cast(i32) v.(json.Float)
        }
    } else when T == State {
        for val, i in arr {
            #partial switch v in val {
                case json.String:
                    ok: bool
                    if strings.compare(v, "DAMAGE") == 0 {
                        r[i] = .DAMAGE
                    } else {
                        assert(false)
                    }
                case:
                    r[i] = .DEFAULT
            }
        }
    }
    return r
}

main :: proc() {
    init()
}

draw_tex :: proc(tex: rl.Texture, pos: rl.Vector2) {
    draw_tex_rot(tex, pos, 0)
}

draw_tex_rot :: proc(tex: rl.Texture, pos: rl.Vector2, angle: f32) {
    using rl
    DrawTexturePro(tex,
    Rectangle{0, 0, cast(f32) tex.width, cast(f32) tex.height},
    Rectangle{pos.x, pos.y, cast(f32) tex.width, cast(f32) tex.height},
    Vector2{cast(f32) tex.width / 2, cast(f32) tex.height / 2},
    angle * (180 / math.π),
    WHITE)
}

@export
init :: proc "c" () {
    rl.InitWindow(800, 600, "TANKERS")
    rl.InitAudioDevice()
    rl.SetTargetFPS(60);
    context = runtime.default_context()
    state.enemy_pos[2] = {40, 400}
    state.enemy_radius[2] = 40

    sounds = make(map[string]rl.Sound)
    impact_tex = rl.LoadTexture("resources/impact.png")
    tank_tex = rl.LoadTexture("resources/tank.png")
    files, err := filepath.glob("resources/*.wav")
    for soundpath in files {
        sounds[filepath.base(soundpath)] = rl.LoadSound(strings.clone_to_cstring(soundpath))
    }

    data, ok := os.read_entire_file("resources/anim/Action1.json")
    assert(ok)
    defer delete(data)

    action1, ok1 := json.parse(data)
    assert(ok1 == nil)

    root := action1.(json.Object)
    animations = make([]Animation, (len(root) - 2) + 1)
    states := load_json_array(State, root["_events"].(json.Array))
    i := 1
    for k in root {
        if k[0] == '_' {
            continue
        }
        anim := Animation{}
        anim.name = k
        anim.pos = load_json_array(rl.Vector2, root[k].(json.Object)["pos"].(json.Array))
        if len(root[k].(json.Object)["frame"].(json.Array)) > 0 {
            rl.TraceLog(.INFO, "add frames for %s", k)
            anim.frame = load_json_array(i32, root[k].(json.Object)["frame"].(json.Array))
        }

        files, err := filepath.glob(strings.concatenate([]string{"resources/", k, "*.png"}, context.temp_allocator))
        assert(err == nil)
        if len(files) > 0 {
            anim.tex = make([]rl.Texture, len(files))
            for f, i in files {
                anim.tex[i] = rl.LoadTexture(strings.clone_to_cstring(f))
            }
        }
        animations[i] = anim
        state.enemy_pose[i].anim = i
        state.enemy_radius[i] = 40
        i += 1
    }
}

PLAYER_RADIUS :: 32
GRAVITY :: rl.Vector2{0,0.5}
state := struct {
    player_pos: [2]rl.Vector2,
    player_pos_old: [2]rl.Vector2,

    bullet_pos: [dynamic]rl.Vector2,
    bullet_pos_old: [dynamic]rl.Vector2,

    beam: rl.Vector2,

    enemy_pos: [10]rl.Vector2,
    enemy_pose: [10]struct{frame: int, anim: int},
    enemy_pos_old: [10]rl.Vector2,
    enemy_radius: [10]f32,
} {
    beam = {400, 300}
}

Stun :: struct {
    time_left: f32,
    cooldown: f32,
}

hitstop := Stun {
    time_left = 0,
    cooldown = 0.4,
}
impacts: small_array.Small_Array(10, rl.Vector2)
impact_timer := cast(f32) 0.0

update_stunned :: proc(h: ^Stun) -> bool {
    if h.time_left > 0 {
        h.time_left -= rl.GetFrameTime()
        if h.time_left <= 0 {
            h.time_left = -h.cooldown
            return false
        } else {
            return true
        }
    } else {
        h.time_left = math.clamp(h.time_left + rl.GetFrameTime(), -100, 0)
        return false
    }
}

stun :: proc(h: ^Stun, amt: f32) -> bool {
    if h.time_left == 0 {
        h.time_left = amt
        return true
    } else {
        return false
    }
}

verlet_integrate :: proc(pos: []rl.Vector2, old_pos: []rl.Vector2) {
    assert(len(pos) == len(old_pos))
    for i := 0; i < len(pos); i+=1 {
        tmp := pos[i]
        pos[i] += (pos[i] - old_pos[i]) + GRAVITY
        old_pos[i] = tmp
    }
}

PLAYER_MAX_DIST :: 200.0
verlet_solve_constraints :: proc(root: rl.Vector2, child: ^rl.Vector2, dist: f32) {
    using linalg

    diff := child^ - root
    diff_len := vector_length(diff)
    if diff_len > dist {
        child^ = root + (diff / diff_len) * dist
    }
}

camera := rl.Camera2D{
    offset = rl.Vector2{400, 300},
    target = rl.Vector2{400, 300},
    zoom = 1,
}

shake_magnitude := cast(f32) 0.0

@export
update :: proc "c" () {
    using rl
    context = runtime.default_context()
    BeginDrawing();
    defer EndDrawing();
    ClearBackground(GRAY);

    { // animate positions
        for i in 0..<len(state.enemy_pose) {
            anim := animations[state.enemy_pose[i].anim]
            if len(anim.pos) > 0 {
                state.enemy_pose[i].frame = (state.enemy_pose[i].frame + 1) % len(anim.pos)
                state.enemy_pos[i] = anim.pos[state.enemy_pose[i].frame]
            }
        }
    }

    up := linalg.normalize(state.player_pos[0] - state.player_pos[1])
    { // logic/physics
        if(!update_stunned(&hitstop)) {
            state.beam.x += math.clamp(cast(f32)GetMouseX() - state.beam.x, -4, 4)
            if IsMouseButtonReleased(.LEFT) {
                left := Vector2{up.y, -up.x}
                // give it a force from the right
                state.player_pos_old[1] += left * 40

                bullet_pos_old := state.player_pos[1] + left * 2
                bullet_pos := bullet_pos_old + left * 40
                append(&state.bullet_pos, bullet_pos)
                append(&state.bullet_pos_old, bullet_pos_old)
            }
            verlet_integrate(state.player_pos[:], state.player_pos_old[:])
            verlet_integrate(state.bullet_pos[:], state.bullet_pos_old[:])
            verlet_integrate(state.enemy_pos[:], state.enemy_pos_old[:])
            for i in 0..<10 {
                state.player_pos[0] = state.beam
                verlet_solve_constraints(state.player_pos[0], &state.player_pos[1], PLAYER_MAX_DIST)
                verlet_solve_constraints(state.enemy_pos[0], &state.enemy_pos[2], 100)
            }

            for enemy_pos, i in state.enemy_pos {
                if state.enemy_radius[i] > 0 && rl.CheckCollisionCircles(enemy_pos, state.enemy_radius[i], state.player_pos[1], PLAYER_RADIUS) {
                    v := state.player_pos[1] - state.player_pos_old[1]
                    rl.TraceLog(.INFO, "hit %f", cast(f64) linalg.vector_length(v))
                    normal := linalg.normalize(state.player_pos[1] - enemy_pos)
                    if linalg.vector_length(v) > 30 {
                        // heavy damage
                        rl.PlaySound(sounds["impact_heavy.wav"])
                        stun(&hitstop, 0.2)
                        shake_magnitude = 4
                        small_array.push(&impacts, enemy_pos + normal * state.enemy_radius[i])
                    } else {
                        rl.SetSoundVolume(sounds["impact.wav"], 0.5 + math.clamp(1, 20, linalg.vector_length(v))/40)
                        rl.SetSoundPitch(sounds["impact.wav"], 0.5 + math.clamp(1, 20, linalg.vector_length(v))/40)
                        rl.PlaySound(sounds["impact.wav"])
                        if linalg.dot(normal, linalg.normalize(state.player_pos[0] - enemy_pos)) > 0 {
                            state.player_pos[1] = enemy_pos + normal * (state.enemy_radius[i] + PLAYER_RADIUS + 0.1)
                            state.player_pos_old[1] = state.player_pos[1] - normal * linalg.vector_length(v) * 0.6
                        } else {
                            tmp := state.player_pos_old[1]
                            state.player_pos_old[1] = state.player_pos[1]
                            state.player_pos[1]= tmp
                        }
                    }
                }
            }
        }
    }

    { // camera shake
        camera.target = rl.Vector2{400, 300} + (shake_magnitude * rl.Vector2{
            noise.noise_2d(1, [2]f64{0, rl.GetTime() * 8}),
            noise.noise_2d(2, [2]f64{0, rl.GetTime() * 8}),
        })
        shake_magnitude = math.max(shake_magnitude - 0.4, 0)
    }

    { // impacts
        if small_array.len(impacts) == 0 {
            impact_timer = 0
        } else {
            impact_timer += rl.GetFrameTime()
            if impact_timer > 0.3 {
                impact_timer = 0
                small_array.pop_front(&impacts)
            }
        }
    }

    BeginMode2D(camera)

    { // draw player
        DrawLineV(state.player_pos[0], state.player_pos[1], rl.BLACK)
        DrawCircle(cast(i32) state.player_pos[0].x, cast(i32) state.player_pos[0].y, 5, RED)

        diff := state.player_pos[0]- state.player_pos[1]
        angle := math.atan2(diff.y, diff.x)
        //DrawRectanglePro(Rectangle{state.player[1].pos.x, state.player[1].pos.y, 10, 40}, rl.Vector2{10, 20}, angle * (180 / math.π), GREEN)
        //turret := state.player[1].pos + up * 10
        //DrawRectanglePro(Rectangle{turret.x, turret.y, 8, 30}, rl.Vector2{10, 25}, angle * (180 / math.π), GREEN)
        draw_tex_rot(tank_tex, state.player_pos[1], angle + math.π / 2)
        DrawCircleLines(cast(i32)state.player_pos[1].x, cast(i32)state.player_pos[1].y, PLAYER_RADIUS, PINK)
    }

    for bullet_pos in state.bullet_pos {
        rl.DrawCircle(cast(i32)bullet_pos.x, cast(i32)bullet_pos.y, 2, WHITE)
    }

    // draw animation
    for enemy_pos, i in state.enemy_pos {
        pose := state.enemy_pose[i]
        anim := animations[pose.anim]
        if pose.anim != 0 && len(anim.frame) > 0 {
            draw_tex(anim.tex[anim.frame[pose.frame]], enemy_pos)
            if state.enemy_radius[i] > 0 {
                rl.DrawCircleLines(cast(i32) enemy_pos.x, cast(i32) enemy_pos.y, state.enemy_radius[i], RED)
            }
        }
    }

    for p in small_array.slice(&impacts) {
        // TODO: add variation to hits
        rl.DrawTextureV(impact_tex, p, WHITE)
    }

    // draw beam
    rl.DrawRectangleRec(Rectangle{x=state.beam.x - 10, y=state.beam.y - 10, width=1000, height=20}, LIGHTGRAY)
    EndMode2D()
}


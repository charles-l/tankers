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
music: rl.Music
boss_face: [4]rl.Texture
hand_r_tex: [2]rl.Texture
hand_l_tex: [2]rl.Texture
bg: rl.Texture

DEBUG :: false

main :: proc() {
    init()
}

dist :: proc(a, b: rl.Vector2) -> f32 {
    return linalg.vector_length(a - b)
}

vclamp :: proc(v: rl.Vector2, len: f32) -> rl.Vector2 {
    l := linalg.vector_length(v)
    if l > len {
        return (v / l) * len
    } else {
        return v
    }
}

draw_tex :: proc(tex: rl.Texture, pos: rl.Vector2) {
    draw_tex_rot(tex, pos, 0)
}

draw_tex_rot :: proc(tex: rl.Texture, pos: rl.Vector2, angle: f32, flipx: f32 = 1.0) {
    using rl
    DrawTexturePro(tex,
    Rectangle{0, 0, cast(f32) tex.width * flipx, cast(f32) tex.height},
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
    state.enemy_radius[0] = 50
    state.enemy_radius[1] = 40
    state.enemy_radius[2] = 40
    music = rl.LoadMusicStream("resources/tankers.mp3")
    rl.PlayMusicStream(music)
    boss_face = [4]rl.Texture{
        rl.LoadTexture("resources/boss-face1.png"),
        rl.LoadTexture("resources/boss-face2.png"),
        rl.LoadTexture("resources/boss-face3.png"),
        rl.LoadTexture("resources/boss-face4.png")}
    hand_r_tex = [2]rl.Texture{rl.LoadTexture("resources/hand_r.001.png"), rl.LoadTexture("resources/hand_r.002.png")}
    hand_l_tex = [2]rl.Texture{rl.LoadTexture("resources/hand_l.002.png"), rl.LoadTexture("resources/hand_l.001.png")}
    // TODO: parallax
    // TODO: birds
    bg = rl.LoadTexture("resources/bg.png")

    sounds = make(map[string]rl.Sound)
    impact_tex = rl.LoadTexture("resources/impact.png")
    tank_tex = rl.LoadTexture("resources/tank.png")
    files, err := filepath.glob("resources/*.wav")
    for soundpath in files {
        sounds[filepath.base(soundpath)] = rl.LoadSound(strings.clone_to_cstring(soundpath))
    }
}

PLAYER_RADIUS :: 32
BULLET_RADIUS :: 4
GRAVITY :: rl.Vector2{0,0.5}
state := struct {
    player_pos: [2]rl.Vector2,
    player_pos_old: [2]rl.Vector2,

    bullet_pos: [dynamic]rl.Vector2,
    bullet_pos_old: [dynamic]rl.Vector2,

    beam: rl.Vector2,

    enemy_pos: [10]rl.Vector2,
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

verlet_integrate :: proc(pos: []rl.Vector2, old_pos: []rl.Vector2, damping: f32 = 1.0) {
    assert(len(pos) == len(old_pos))
    for i := 0; i < len(pos); i+=1 {
        tmp := pos[i]
        pos[i] += ((pos[i] - old_pos[i]) + GRAVITY) * damping
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

BossState :: enum {
    Idle,
    Chase,
    Guard,
    Spinning,
}

update_hand :: proc(body, target: rl.Vector2, limb: ^rl.Vector2, bstate: BossState) {
    verlet_solve_constraints(body, limb, 100)
    up := linalg.normalize(body - limb^)
    left := rl.Vector2{up.y, -up.x}
    #partial switch bstate {
        case .Guard:
            err := linalg.normalize(body - limb^) - ({0.3, target.y * 0.1 - 0.2})
            limb^ += -err * 10
        case .Spinning:
            limb^ += left * 6
        case:
            err := linalg.normalize(body - limb^) - linalg.normalize(target + 0.4 * math.sin(cast(f32) rl.GetTime() + target.x))
            limb^ += -err
    }
}

boss_state_time: f32 = 2.0
boss_state: BossState

@export
update :: proc "c" () {
    using rl
    context = runtime.default_context()
    BeginDrawing();
    defer EndDrawing();
    ClearBackground(GRAY);
    rl.DrawTexture(bg, 0, 0, WHITE)
    rl.UpdateMusicStream(music)

    up := linalg.normalize(state.player_pos[0] - state.player_pos[1])
    { // logic/physics
        if(!update_stunned(&hitstop)) {
            state.beam.x += math.clamp(cast(f32)GetMouseX() - state.beam.x, -4, 4)
            if IsMouseButtonReleased(.LEFT) {
                left := Vector2{up.y, -up.x}
                // give it a force from the right
                state.player_pos_old[1] += left * 40

                // TODO: add muzzle flash
                rl.PlaySound(sounds["shot.wav"])

                { // aim assist
                    ideal := linalg.normalize(state.enemy_pos[0] + {0, -70} - state.player_pos[1])
                    d := linalg.dot(ideal, left)
                    if 0.8 < d && d < 1 {
                        rl.TraceLog(.INFO, "aim assist %f", cast(f64) linalg.dot(ideal, left))
                        left = ideal
                    }
                }

                bullet_pos_old := state.player_pos[1]
                bullet_pos := bullet_pos_old + left * 30

                append(&state.bullet_pos, bullet_pos)
                append(&state.bullet_pos_old, bullet_pos_old)
            }
            verlet_integrate(state.player_pos[:], state.player_pos_old[:])
            verlet_integrate(state.bullet_pos[:], state.bullet_pos_old[:])
            verlet_integrate(state.enemy_pos[:], state.enemy_pos_old[:], 0.7)

            if boss_state == .Idle {
                state.enemy_pos[0] = {math.sin(cast(f32) rl.GetTime() / 2) * 30 + 90, math.sin(cast(f32) rl.GetTime() / 3) * 20 + 400}
            } else if boss_state == .Chase || boss_state == .Spinning {
                state.enemy_pos[0] += vclamp((state.player_pos[1] - {80, 0}) - state.enemy_pos[0], 4)
            } else {
                state.enemy_pos[0] += vclamp({40, 400} - state.enemy_pos[0], 1)
            }

            boss_state_time -= rl.GetFrameTime()
            if boss_state_time < 0 {
                if dist(state.player_pos[1], state.enemy_pos[0]) < 400{
                    boss_state = .Spinning
                } else {
                    if rl.GetRandomValue(0, 10) < 5 {
                        boss_state = .Idle
                    } else {
                        boss_state = .Chase
                    }
                }

                boss_state_time = 2
            }

            update_hand(state.enemy_pos[0], rl.Vector2{1, 1}, &state.enemy_pos[1], boss_state)
            update_hand(state.enemy_pos[0], rl.Vector2{1, 1.9}, &state.enemy_pos[2], boss_state)

            for i in 0..<10 {
                state.player_pos[0] = state.beam
                verlet_solve_constraints(state.player_pos[0], &state.player_pos[1], PLAYER_MAX_DIST)
            }


            for i := 0; i < len(state.bullet_pos); {
                bullet_pos := state.bullet_pos[i]
                for enemy_pos, j in state.enemy_pos {
                    if rl.CheckCollisionCircles(enemy_pos, state.enemy_radius[j], bullet_pos, BULLET_RADIUS) {
                        rl.PlaySound(sounds["dirt_impact.wav"])
                        state.bullet_pos[i].y = 10000
                        boss_state = .Guard
                        boss_state_time = 2
                    }
                }
                if bullet_pos.y > 10000 {
                    ordered_remove(&state.bullet_pos, i)
                    ordered_remove(&state.bullet_pos_old, i)
                    continue
                } else {
                    i += 1
                }
            }

            // collisions
            for enemy_pos, i in state.enemy_pos {
                if state.enemy_radius[i] == 0 {
                    continue
                }
                if rl.CheckCollisionCircles(enemy_pos, state.enemy_radius[i], state.player_pos[1], PLAYER_RADIUS) {
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

        diff := state.player_pos[0]- state.player_pos[1]
        angle := math.atan2(diff.y, diff.x)
        //DrawRectanglePro(Rectangle{state.player[1].pos.x, state.player[1].pos.y, 10, 40}, rl.Vector2{10, 20}, angle * (180 / math.π), GREEN)
        //turret := state.player[1].pos + up * 10
        //DrawRectanglePro(Rectangle{turret.x, turret.y, 8, 30}, rl.Vector2{10, 25}, angle * (180 / math.π), GREEN)
        draw_tex_rot(tank_tex, state.player_pos[1], angle + math.π / 2)
        when DEBUG {
            DrawCircleLines(cast(i32)state.player_pos[1].x, cast(i32)state.player_pos[1].y, PLAYER_RADIUS, PINK)
        }
    }

    for bullet_pos in state.bullet_pos {
        rl.DrawCircle(cast(i32)bullet_pos.x, cast(i32)bullet_pos.y, BULLET_RADIUS, WHITE)
    }

    // draw animation
    for enemy_pos, i in state.enemy_pos {
        //draw_tex(anim.tex[anim.frame[pose.frame]], enemy_pos)
        if i == 0 {
            switch boss_state {
                case .Idle:
                draw_tex(boss_face[0], enemy_pos)
                case .Guard:
                draw_tex(boss_face[2], enemy_pos)
                case .Spinning:
                draw_tex(boss_face[1], enemy_pos)
                case .Chase:
                draw_tex(boss_face[3], enemy_pos)
            }
        }
        if i == 1 {
            switch boss_state {
                case .Idle:
                draw_tex(hand_l_tex[1], enemy_pos)
                case .Guard:
                draw_tex_rot(hand_r_tex[1], enemy_pos, math.π / 2 + 0.5, -1)
                case .Spinning, .Chase:
                draw_tex(hand_l_tex[0], enemy_pos)
            }
        }
        if i == 2 {
            switch boss_state {
                case .Idle:
                draw_tex(hand_r_tex[1], enemy_pos)
                case .Guard:
                draw_tex_rot(hand_l_tex[1], enemy_pos, math.π / 2 + 0.5, -1)
                case .Spinning, .Chase:
                draw_tex(hand_r_tex[0], enemy_pos)
            }
        }
        if state.enemy_radius[i] > 0 {
            when DEBUG {
                rl.DrawCircleLines(cast(i32) enemy_pos.x, cast(i32) enemy_pos.y, state.enemy_radius[i], RED)
            }
        }
    }

    for p in small_array.slice(&impacts) {
        // TODO: add variation to hits
        rl.DrawTextureV(impact_tex, p, WHITE)
    }

    // draw beam
    rl.DrawRectangleRec(Rectangle{x=state.beam.x - 10, y=state.beam.y - 10, width=1000, height=20}, GRAY)
    EndMode2D()
}


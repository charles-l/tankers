package main
import rl "raylib"
import c "core:c"
import "core:math"
import "core:math/linalg"
import "core:math/noise"

import "core:runtime"
import "core:fmt"
import "core:container/small_array"
import "core:path/filepath"
import "core:strings"

// TODO scenarios:
// tank vs tank (two pendelums)
// tank vs small enemies, lead up to miniboss?
// tank (on helicopter) vs boss

print :: fmt.println

@export
_fltused: c.int = 0

impact_tex: rl.Texture
sounds: map[string]rl.Sound
@export
init :: proc "c" () {
    rl.InitWindow(800, 600, "TANKERS")
    rl.InitAudioDevice()
    rl.SetTargetFPS(60);
    context = runtime.default_context()
    state.enemies[0].pos = {40, 400}
    state.enemy_radius[0] = 40

    sounds = make(map[string]rl.Sound)
    impact_tex = rl.LoadTexture("resources/impact.png")
    files, err := filepath.glob("resources/*.wav")
    for soundpath in files {
        sounds[filepath.base(soundpath)] = rl.LoadSound(strings.clone_to_cstring(soundpath))
    }
}

Position :: struct {
    pos: rl.Vector2,
    old_pos: rl.Vector2,
}

PLAYER_RADIUS :: 20
GRAVITY :: rl.Vector2{0,0.5}
state := struct {
    player: [2]Position,
    bullets: [dynamic]Position,
    beam: rl.Vector2,

    enemies: [10]Position,
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

verlet_integrate :: proc(ps: []Position) {
    for i := 0; i < len(ps); i+=1 {
        tmp := ps[i].pos
        ps[i].pos += (ps[i].pos - ps[i].old_pos) + GRAVITY
        ps[i].old_pos = tmp
    }
}

verlet_solve_constraints :: proc(ps: []Position, endpoint0: rl.Vector2) {
    using linalg
    MAX_DIST :: 200.0
    ps[0].pos = endpoint0

    //if vector_length(pos[0] - pos[len(pos)-1]) > DIST_GOAL * cast(f32) len(pos) {
    //    for i := 1; i < len(pos); i += 1 {
    //        diff := pos[0] - pos[i]
    //        dist := vector_length(diff)
    //        err := ((DIST_GOAL * cast(f32)i) - dist) / dist
    //        translate := diff * err
    //        pos[i] -= translate
    //    }
    //}

    diff := ps[1].pos - ps[0].pos
    diff_len := vector_length(diff)
    if diff_len > MAX_DIST {
        ps[1].pos = ps[0].pos + (diff / diff_len) * MAX_DIST
    }

    //for i := 0; i < len(pos) - 1; i += 1 {
    //    n1 := &pos[i]
    //    n2 := &pos[i+1]

    //    {
    //        diff := n1^ - n2^
    //        dist := linalg.vector_length(diff)

    //        err: f32 = 0.0
    //        if dist > 0 {
    //            err = (DIST_GOAL - dist) / dist
    //        } else {
    //            err = 1
    //            diff = rl.Vector2{0, 1}
    //        }

    //        if i == 0 {
    //            translate := diff * err
    //            n2^ = n2^ - translate
    //        } else {
    //            translate := diff * 0.5 * err
    //            n1^ = n1^ + translate
    //            n2^ = n2^ - translate
    //        }
    //    }
    //}
}

get_vel :: proc(p: Position) -> rl.Vector2 {
    return p.pos - p.old_pos
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

    up := linalg.normalize(state.player[0].pos - state.player[1].pos)
    { // logic/physics
        if(!update_stunned(&hitstop)) {
            state.beam.x += math.clamp(cast(f32)GetMouseX() - state.beam.x, -4, 4)
            if IsMouseButtonReleased(.LEFT) {
                left := Vector2{-up.y, up.x}
                state.player[1].old_pos += -left * 40

                bullet_old_pos := state.player[1].pos + left * 2
                bullet_pos := bullet_old_pos[0] + -left * 40
                append(&state.bullets, Position{bullet_pos, bullet_old_pos})
            }
            verlet_integrate(state.player[:])
            verlet_integrate(state.bullets[:])
            for i in 0..<10 {
                verlet_solve_constraints(state.player[:], state.beam)
            }

            for enemy, i in state.enemies {
                if state.enemy_radius[i] > 0 && rl.CheckCollisionCircles(enemy.pos, state.enemy_radius[i], state.player[1].pos, PLAYER_RADIUS) {
                    v := get_vel(state.player[1])
                    rl.TraceLog(.INFO, "hit %f", cast(f64) linalg.vector_length(v))
                    normal := linalg.normalize(state.player[1].pos - enemy.pos)
                    if linalg.vector_length(v) > 30 {
                        // heavy damage
                        rl.PlaySound(sounds["impact_heavy.wav"])
                        stun(&hitstop, 0.2)
                        shake_magnitude = 4
                        small_array.push(&impacts, enemy.pos + normal * state.enemy_radius[i])
                    } else {
                        rl.SetSoundVolume(sounds["impact.wav"], 0.5 + math.clamp(1, 20, linalg.vector_length(v))/40)
                        rl.SetSoundPitch(sounds["impact.wav"], 0.5 + math.clamp(1, 20, linalg.vector_length(v))/40)
                        rl.PlaySound(sounds["impact.wav"])
                        if linalg.dot(normal, linalg.normalize(state.player[0].pos - enemy.pos)) > 0 {
                            state.player[1].pos = enemy.pos + normal * (state.enemy_radius[i] + PLAYER_RADIUS + 0.1)
                            state.player[1].old_pos = state.player[1].pos - normal * linalg.vector_length(v) * 0.6
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
        DrawLineV(state.player[0].pos, state.player[1].pos, rl.BLACK)
        DrawCircle(cast(i32) state.player[0].pos.x, cast(i32) state.player[0].pos.y, 5, RED)

        diff := state.player[0].pos - state.player[1].pos
        angle := math.atan2(diff.y, diff.x)
        DrawRectanglePro(Rectangle{state.player[1].pos.x, state.player[1].pos.y, 10, 40}, rl.Vector2{10, 20}, angle * (180 / math.π), GREEN)
        turret := state.player[1].pos + up * 10
        DrawRectanglePro(Rectangle{turret.x, turret.y, 8, 30}, rl.Vector2{10, 25}, angle * (180 / math.π), GREEN)
        DrawCircleLines(cast(i32)state.player[1].pos.x, cast(i32)state.player[1].pos.y, PLAYER_RADIUS, PINK)
    }

    for bullet in state.bullets {
        rl.DrawCircle(cast(i32)bullet.pos.x, cast(i32)bullet.pos.y, 2, WHITE)
    }

    for enemy, i in state.enemies {
        if state.enemy_radius[i] > 0 {
            rl.DrawCircle(cast(i32)enemy.pos.x, cast(i32)enemy.pos.y, state.enemy_radius[i], RED)
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


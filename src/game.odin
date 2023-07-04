package main
import rl "raylib"
import "core:c"
import "core:fmt"
import "core:os"
import "core:math"
import "core:math/linalg"
import "core:math/noise"
import "core:encoding/json"
import "core:slice"

import "core:runtime"
import "core:container/small_array"
import "core:path/filepath"
import "core:strings"

GameState :: enum {
    Gameplay,
    Victory,
    Victory_Final,
    Lose,
}

LevelProcs :: struct {
    init: proc(^State),
    update: proc(^State, []EnemyEvent),
    draw: proc(State, int, rl.Color),
    win_state: GameState,
}

// TODO scenarios:
// tank vs small enemies, lead up to miniboss?

@export
_fltused: c.int = 0

impact_tex: rl.Texture
tank_tex: rl.Texture
sounds: map[string]rl.Sound
songs: [2]rl.Music
music: rl.Music
victory_music: rl.Music
boss_face: [4]rl.Texture
hand_r_tex: [2]rl.Texture
hand_l_tex: [2]rl.Texture
jetblast_tex: rl.Texture
enemy_tex: rl.Texture
dirt_tex: rl.Texture
explosion_tex: rl.Texture
boss_death_tex: rl.Texture
flash_tex: rl.Texture
bg: [3]rl.Texture

state: State

DEBUG :: false

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

draw_text_centered :: proc(text: cstring, size: i32) {
    spacing := size / 10
    s := rl.MeasureTextEx(rl.GetFontDefault(), text, cast(f32) size, cast(f32) spacing)
    rl.DrawText(text, rl.GetScreenWidth() / 2 - cast(i32) s.x / 2, rl.GetScreenHeight() / 2 - cast(i32) s.y / 2 + 4, size, rl.BLACK)
    rl.DrawText(text, rl.GetScreenWidth() / 2 - cast(i32) s.x / 2, rl.GetScreenHeight() / 2 - cast(i32) s.y / 2, size, rl.WHITE)
}

draw_tex :: proc(tex: rl.Texture, pos: rl.Vector2, color: rl.Color = rl.WHITE) {
    draw_tex_rot(tex, pos, 0, 1.0, color)
}

draw_tex_rot :: proc(tex: rl.Texture, pos: rl.Vector2, angle: f32, flipx: f32 = 1.0, color: rl.Color = rl.WHITE) {
    using rl
    DrawTexturePro(tex,
    Rectangle{0, 0, cast(f32) tex.width * flipx, cast(f32) tex.height},
    Rectangle{pos.x, pos.y, cast(f32) tex.width, cast(f32) tex.height},
    Vector2{cast(f32) tex.width / 2, cast(f32) tex.height / 2},
    angle * (180 / math.π),
    color)
}

enemy_event: [dynamic]EnemyEvent

reset_level :: proc(state: ^State) {
    level := state.level
    rl.StopMusicStream(music)
    music = songs[level]
    rl.PlayMusicStream(music)

    state^ = State{
        aim_assist = false,
        level = level,
        player = PlayerAlive{pos={400, 500}, pos_old={400, 500}, health=10},
        beam = {400, 300},
    }

    levels[state.level].init(state)
    resize(&enemy_event, len(state.enemy_pos))
}

init_boss :: proc(state: ^State) {
    state.aim_assist = true
    music = rl.LoadMusicStream("resources/tankers.mp3")
    rl.PlayMusicStream(music)

    state.enemy_pos[0] = {40, 400}
    state.enemy_pos_old[0] = state.enemy_pos[0]
    state.enemy_radius[0] = 50
    state.enemy_radius[1] = 20
    state.enemy_radius[2] = 20

    state.enemy_damage_mask[0] += {.Bullet}
    state.enemy_damage_mask[1] += {.Hit}
    state.enemy_damage_mask[2] += {.Hit}

    state.enemy_health[0] = 100
    state.enemy_health[1] = 20
    state.enemy_health[2] = 20
    state.boss_state_time = 2
}

update_boss :: proc(state: ^State, events: []EnemyEvent) {
    state.boss_state_time -= rl.GetFrameTime()
    player, alive := state.player.(PlayerAlive)

    if state.enemy_health[1] <= 0 && state.enemy_health[2] <= 0 {
        state.enemy_damage_mask[0] += {.Hit}
    }

    for e in events {
        if e == .Damage {
            state.boss_state = .Guard
            state.boss_state_time = 2
            break
        }
    }

    if !alive {
        state.boss_state = .Idle
    } else {
        if state.boss_state_time < 0 {
            if dist(player.pos, state.enemy_pos[0]) < 400{
                state.boss_state = .Spinning
            } else {
                if rl.GetRandomValue(0, 10) < 5 {
                    state.boss_state = .Idle
                } else {
                    state.boss_state = .Chase
                }
            }

            state.boss_state_time = 2
        }
    }
    target := rl.Vector2{40, 400}
    speed: f32 = 1.0
    #partial switch state.boss_state {
        case .Idle:
        target = {math.sin(cast(f32) rl.GetTime() / 2) * 30 + 90, math.sin(cast(f32) rl.GetTime() / 3) * 20 + 400}
        case .Chase:
        target = player.pos - {190, 0}
        speed = 3
        case .Spinning:
        target = player.pos - {100, 0}
        case:
        // pass
    }
    state.enemy_pos[0] += vclamp(target - state.enemy_pos[0], speed)

    update_hand(state.enemy_pos[0], rl.Vector2{1, 1}, &state.enemy_pos[1], state.boss_state)
    update_hand(state.enemy_pos[0], rl.Vector2{1, 1.9}, &state.enemy_pos[2], state.boss_state)
}

draw_boss :: proc(state: State, i: int, color: rl.Color) {
    enemy_pos := state.enemy_pos[i]
    if i == 0 {
        switch state.boss_state {
            case .Idle:
            draw_tex(boss_face[0], enemy_pos, color)
            case .Guard:
            draw_tex(boss_face[2], enemy_pos, color)
            case .Spinning:
            draw_tex(boss_face[1], enemy_pos, color)
            case .Chase:
            draw_tex(boss_face[3], enemy_pos, color)
        }
    }
    if i == 1 {
        switch state.boss_state {
            case .Idle:
            draw_tex(hand_l_tex[1], enemy_pos, color)
            case .Guard:
            draw_tex_rot(hand_r_tex[1], enemy_pos, math.π / 2 + 0.5, -1, color)
            case .Spinning, .Chase:
            draw_tex(hand_l_tex[0], enemy_pos, color)
        }
    }
    if i == 2 {
        switch state.boss_state {
            case .Idle:
            draw_tex(hand_r_tex[1], enemy_pos, color)
            case .Guard:
            draw_tex_rot(hand_l_tex[1], enemy_pos, math.π / 2 + 0.5, -1, color)
            case .Spinning, .Chase:
            draw_tex(hand_r_tex[0], enemy_pos, color)
        }
    }
}

init_level1 :: proc(state: ^State) {
    music = rl.LoadMusicStream("resources/tankers-combat.mp3")
    rl.PlayMusicStream(music)

    for i in 0..<40 {
        state.enemy_health[i] = 10
        state.enemy_radius[i] = 12
        state.enemy_pos[i] = {20, cast(f32)i * 20}
        state.enemy_damage_mask[i] += {.Bullet, .Hit}
    }
}

update_level1 :: proc(state: ^State, events: []EnemyEvent) {
    for pos, i in state.enemy_pos {
        if state.enemy_radius[i] <= 0 {
            continue
        }

        target := rl.Vector2{1000, 400}
        if player, player_alive := state.player.(PlayerAlive); player_alive {
            if (cast(i32) rl.GetTime()) % 10 < 2 {
                target = player.pos
            } else {
                target = {100, player.pos.y + 10}
            }
        }

        alignmentv := rl.Vector2{}
        separationv := rl.Vector2{}
        cohesionv := rl.Vector2{}
        {
            nb_count := cast(f32) 0.0
            other_alive := 0
            for other_pos, j in state.enemy_pos {
                if state.enemy_radius[j] <= 0 || j == i {
                    continue
                }

                d := dist(other_pos, pos)
                if d < 40 {
                    separationv += linalg.normalize(pos - other_pos) * (40 - d)
                }

                other_v := other_pos - state.enemy_pos_old[j]
                alignmentv += other_v

                cohesionv += other_pos
                other_alive += 1
            }

            if other_alive > 0 {
                cohesionv /= cast(f32) other_alive
                cohesionv -= pos
            }

            alignmentv /= 8
        }

        //v := vclamp(target - pos, 0.5) + (0.15 * alignmentv) + (0.3 * separationv) + (0.05 * cohesionv)
        //v := vclamp(target - pos, 0.3) + (0.2 * alignmentv) + (0.5 * separationv) //+ (0.05 * cohesionv)
        v := vclamp(vclamp(target - pos, 30) + alignmentv + separationv + vclamp(cohesionv, 5), 2)

        state.enemy_pos[i] += v
    }
}

draw_level1 :: proc(state: State, i: int, color: rl.Color) {
    draw_tex(enemy_tex, state.enemy_pos[i], color)
}

EnemyEvent :: enum {
    None,
    Damage,
    Died,
}
apply_bullet_damage :: proc(
    bullet_pos: ^[dynamic]rl.Vector2,
    bullet_pos_old: ^[dynamic]rl.Vector2,
    enemy_poss: []rl.Vector2,
    enemy_radius: []f32,
    enemy_damage_mask: []bit_set[DamageMask],
    enemy_health: []f32,
    enemy_event: []EnemyEvent, // out
) {
    for i := 0; i < len(bullet_pos); {
        for enemy_pos, j in enemy_poss {
            if rl.CheckCollisionCircles(enemy_pos, enemy_radius[j], bullet_pos[i], BULLET_RADIUS) {
                dir := linalg.normalize(bullet_pos[i] - bullet_pos_old[i])
                enemy_poss[j] -= dir * 4
                rl.PlaySound(sounds["dirt_impact.wav"])

                if .Bullet in enemy_damage_mask[j] {
                    enemy_health[j] -= 10
                    enemy_event[j] = .Damage
                }

                small_array.push(&impacts, Impact{
                    pos = bullet_pos[i],
                    ttl = 0.2,
                    tex = &dirt_tex,
                    frames = 3,
                })

                bullet_pos[i].y = 10000
            }
        }
        if bullet_pos[i].y > 10000 {
            ordered_remove(bullet_pos, i)
            ordered_remove(bullet_pos_old, i)
            continue
        } else {
            i += 1
        }
    }
}

levels := [?]LevelProcs {
    {
        init = init_level1,
        update = update_level1,
        draw = draw_level1,
        win_state = .Victory,
    },
    {
        init = init_boss,
        update = update_boss,
        draw = draw_boss,
        win_state = .Victory_Final,
    }
}


@export
init :: proc "c" () {
    rl.InitWindow(800, 600, "TANKERS")
    rl.InitAudioDevice()
    rl.SetTargetFPS(60);
    context = runtime.default_context()
    // NOTE: THIS IS NECESSARY FOR A LOT OF ODIN TYPES TO WORK
    #force_no_inline runtime._startup_runtime()

    victory_music = rl.LoadMusicStream("resources/tankers-victory.mp3")
    victory_music.looping = false
    rl.PlayMusicStream(victory_music)

    enemy_tex = rl.LoadTexture("resources/enemy.png")
    jetblast_tex = rl.LoadTexture("resources/jetblast.png")
    boss_face = [4]rl.Texture{
        rl.LoadTexture("resources/boss-face1.png"),
        rl.LoadTexture("resources/boss-face2.png"),
        rl.LoadTexture("resources/boss-face3.png"),
        rl.LoadTexture("resources/boss-face4.png")}
    hand_r_tex = [2]rl.Texture{rl.LoadTexture("resources/hand_r.001.png"), rl.LoadTexture("resources/hand_r.002.png")}
    hand_l_tex = [2]rl.Texture{rl.LoadTexture("resources/hand_l.002.png"), rl.LoadTexture("resources/hand_l.001.png")}
    flash_tex = rl.LoadTexture("resources/muzzleflash.png")
    dirt_tex = rl.LoadTexture("resources/dirtimpact.png")
    explosion_tex = rl.LoadTexture("resources/explosion.png")
    boss_death_tex = rl.LoadTexture("resources/boss-death.png")
    // TODO: parallax
    // TODO: birds
    bg = {
        rl.LoadTexture("resources/bg0.png"),
        rl.LoadTexture("resources/bg1.png"),
        rl.LoadTexture("resources/bg2.png"),
    }

    sounds = make(map[string]rl.Sound)
    impact_tex = rl.LoadTexture("resources/impact.png")
    tank_tex = rl.LoadTexture("resources/tank.png")
    files, err := filepath.glob("resources/*.wav")
    for soundpath in files {
        sounds[filepath.base(soundpath)] = rl.LoadSound(strings.clone_to_cstring(soundpath))
    }

    rl.SetSoundVolume(sounds["ratchet_1.wav"], 0.4)
    rl.SetSoundVolume(sounds["ratchet_2.wav"], 0.4)

    songs[0] = rl.LoadMusicStream("resources/tankers-combat.mp3")
    songs[1] = rl.LoadMusicStream("resources/tankers.mp3")

    music = songs[0]

    reset_level(&state)
}

PlayerAlive :: struct {
    pos: rl.Vector2,
    pos_old: rl.Vector2,
    health: f32,
}

PlayerDead :: struct {}

DamageMask :: enum {
    Bullet,
    Hit,
}

PLAYER_RADIUS :: 32
PLAYER_HURT_RADIUS :: PLAYER_RADIUS * 0.55
BULLET_RADIUS :: 4
GRAVITY :: rl.Vector2{0,0.5}

State :: struct {
    ratchet: int,
    rotations: int,
    aim_assist: bool,
    level: int,
    player: union{
        PlayerAlive,
        PlayerDead,
    },

    game_state: GameState,

    bullet_pos: [dynamic]rl.Vector2,
    bullet_pos_old: [dynamic]rl.Vector2,

    beam: rl.Vector2,

    enemy_pos: [40]rl.Vector2,
    enemy_pos_old: [40]rl.Vector2,
    enemy_radius: [40]f32,
    enemy_health: [40]f32,
    enemy_damage_mask: [40]bit_set[DamageMask],
    enemy_last_damage_time: [40]f32,

    boss_state_time: f32,
    boss_state: BossState,
}

Stun :: struct {
    time_left: f32,
    cooldown: f32,
}

Limiter :: struct {
    last_time: f32,
    cooldown: f32,
}

hitstop := Stun {
    cooldown = 0.4,
}

hitsfx_limiter := Limiter {
    cooldown = 0.2
}

damage_limiter := Limiter {
    cooldown = 0.4
}

Impact :: struct {
    pos: rl.Vector2,
    time: f32,
    ttl: f32,

    tex: ^rl.Texture,
    frames: i32,
}

impacts: small_array.Small_Array(20, Impact)

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

trigger :: proc(h: ^Limiter) -> bool {
    t := cast(f32) rl.GetTime()
    if t - h.last_time > h.cooldown {
        h.last_time = t
        return true
    } else {
        return false
    }
}

is_limited :: proc(h: ^Limiter) -> bool {
    t := cast(f32) rl.GetTime()
    return t - h.last_time <= h.cooldown
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

vec_up :: proc(v1: rl.Vector2, v2: rl.Vector2) -> rl.Vector2 {
    return linalg.normalize(v1 - v2)
}

vec_ccw :: proc(v: rl.Vector2) -> rl.Vector2 {
    return rl.Vector2{v.y, -v.x}
}

victory_time := 0.0

@export
update :: proc "c" () {
    using rl
    context = runtime.default_context()
    defer free_all(context.temp_allocator)
    BeginDrawing();
    defer EndDrawing();
    ClearBackground(GRAY);
    rl.DrawTexturePro(bg[0],
        rl.Rectangle{cast(f32) -rl.GetTime() * 8, 0, cast(f32) bg[0].width, cast(f32) bg[0].height},
        rl.Rectangle{0, 0, cast(f32) bg[0].width, cast(f32) bg[0].height},
        {0, 0},
        0,
        WHITE)
    rl.DrawTexturePro(bg[1],
        rl.Rectangle{cast(f32) -rl.GetTime() * 16, 0, cast(f32) bg[0].width, cast(f32) bg[0].height},
        rl.Rectangle{0, 0, cast(f32) bg[0].width, cast(f32) bg[0].height},
        {0, 0},
        0,
        WHITE)
    rl.DrawTexturePro(bg[2],
        rl.Rectangle{cast(f32) -rl.GetTime() * 20, 0, cast(f32) bg[0].width, cast(f32) bg[0].height},
        rl.Rectangle{0, 0, cast(f32) bg[0].width, cast(f32) bg[0].height},
        {0, 0},
        0,
        WHITE)
    rl.UpdateMusicStream(music)

    // frame vars
    jetblast := false
    for _, i in enemy_event {
        enemy_event[i] = .None
    }

    if rl.IsKeyReleased(.LEFT_BRACKET) {
        state.level -= 1
        reset_level(&state)
    }

    if rl.IsKeyReleased(.RIGHT_BRACKET) {
        state.level += 1
        reset_level(&state)
    }

    { // logic/physics
        if(!update_stunned(&hitstop)) {
            verlet_integrate(state.bullet_pos[:], state.bullet_pos_old[:])
            apply_bullet_damage(
                &state.bullet_pos,
                &state.bullet_pos_old,
                state.enemy_pos[:],
                state.enemy_radius[:],
                state.enemy_damage_mask[:],
                state.enemy_health[:],
                enemy_event[:],
            )

            for ev, i in enemy_event {
                if ev == .Damage {
                    state.enemy_last_damage_time[i] = cast(f32) rl.GetTime()
                }
            }

            { // player update
                state.beam.x += math.clamp(cast(f32)GetMouseX() - state.beam.x, -4, 4)
                switch player in &state.player {
                    case PlayerAlive:
                    if IsMouseButtonReleased(.LEFT) {
                        left := vec_ccw(vec_up(state.beam, player.pos))
                        // give it a force from the right
                        player.pos_old += left * 40

                        rl.PlaySound(sounds["shot.wav"])

                        if state.aim_assist {
                            ideal := linalg.normalize(state.enemy_pos[0] + {0, -70} - player.pos)
                            d := linalg.dot(ideal, left)
                            if 0.8 < d && d < 1 {
                                rl.TraceLog(.INFO, "aim assist %f", cast(f64) linalg.dot(ideal, left))
                                left = ideal
                            }
                        }

                        small_array.push(&impacts, Impact{
                            pos = player.pos + left * 30,
                            ttl = 0.2,
                            tex = &flash_tex,
                            frames = 3,
                        })

                        bullet_pos_old := player.pos
                        bullet_pos := bullet_pos_old + left * 30

                        append(&state.bullet_pos, bullet_pos)
                        append(&state.bullet_pos_old, bullet_pos_old)
                    }

                    if IsMouseButtonDown(.RIGHT) {
                        jetblast = true
                        right := -vec_ccw(vec_up(state.beam, player.pos))
                        player.pos_old += right * 0.8
                    }

                    verlet_integrate(slice.from_ptr(&player.pos, 1), slice.from_ptr(&player.pos_old, 1))
                    for i in 0..<10 {
                        verlet_solve_constraints(state.beam, &player.pos, PLAYER_MAX_DIST)
                    }

                    case PlayerDead:
                    //pass
                }
            }

            verlet_integrate(state.enemy_pos[:], state.enemy_pos_old[:], 0.7)
            levels[state.level].update(&state, enemy_event[:])

            for enemy_pos, i in state.enemy_pos {
                if state.enemy_health[i] <= 0 {
                    state.enemy_radius[i] = 0
                }
                if state.enemy_radius[i] == 0 {
                    continue
                }
                if player, player_alive := &state.player.(PlayerAlive); player_alive && rl.CheckCollisionCircles(enemy_pos, state.enemy_radius[i], player.pos, PLAYER_RADIUS) {
                    ev := enemy_pos - state.enemy_pos_old[i]
                    v := player.pos - player.pos_old
                    normal := linalg.normalize(player.pos - enemy_pos)
                    if linalg.vector_length(v) > 30 && .Hit in state.enemy_damage_mask[i] {
                        // TODO: Have to charge up invincible mode to smack them
                        // heavy damage
                        if trigger(&hitsfx_limiter) {
                            rl.PlaySound(sounds["impact_heavy.wav"])
                        }
                        stun(&hitstop, 0.2)
                        shake_magnitude = 4

                        state.enemy_health[i] -= 10
                        enemy_event[i] = .Damage

                        small_array.push(&impacts, Impact{
                            pos = enemy_pos + normal * state.enemy_radius[i],
                            ttl = 0.2,
                            tex = &impact_tex,
                            frames = 1,
                        })

                        small_array.push(&impacts, Impact{
                            pos = enemy_pos,
                            ttl = 0.3,
                            tex = &dirt_tex,
                            frames = 3,
                        })
                    } else {
                        if linalg.vector_length(v) > 1 {
                            if trigger(&hitsfx_limiter) {
                                rl.SetSoundVolume(sounds["impact.wav"], 0.5 + math.clamp(1, 20, linalg.vector_length(v))/40)
                                rl.SetSoundPitch(sounds["impact.wav"], 0.5 + math.clamp(1, 20, linalg.vector_length(v))/40)
                                rl.PlaySound(sounds["impact.wav"])
                            }
                        }
                        // passthrough
                        if linalg.dot(normal, linalg.normalize(state.beam - enemy_pos)) > 0 {
                            player.pos = enemy_pos + normal * (state.enemy_radius[i] + PLAYER_RADIUS + 0.1)
                            player.pos_old = player.pos - normal * linalg.vector_length(v) * 0.6
                        } else {
                            tmp := player.pos_old
                            player.pos_old = player.pos
                            player.pos= tmp
                        }

                        // hurt player
                        if linalg.vector_length(ev) > 10 && rl.CheckCollisionCircles(enemy_pos, state.enemy_radius[i], player.pos, PLAYER_HURT_RADIUS) {
                            player.pos += linalg.normalize(ev) * 3
                            if trigger(&damage_limiter) {
                                player.health -= 10
                                stun(&hitstop, 0.4)
                            }

                            if player.health < 0 {
                                small_array.push(&impacts, Impact{
                                    pos = player.pos,
                                    ttl = 0.6,
                                    tex = &explosion_tex,
                                    frames = 6,
                                })
                                state.player = PlayerDead{}
                            }
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
        for i := 0; i < small_array.len(impacts); {
            impact := small_array.get_ptr(&impacts, i)
            impact.time += rl.GetFrameTime()
            if impact.time > impact.ttl {
                small_array.ordered_remove(&impacts, i)
            } else {
                i += 1
            }
        }
    }

    BeginMode2D(camera)

    _, ok := state.player.(PlayerAlive)
    if player, player_alive := state.player.(PlayerAlive); player_alive { // draw player
        DrawLineV(state.beam, player.pos, rl.BLACK)

        old_diff := state.beam - player.pos_old
        diff := state.beam - player.pos

        old_angle := math.atan2(old_diff.y, old_diff.x)
        angle := math.atan2(diff.y, diff.x)

        if diff.x > 0 && old_diff.y < 0 && diff.y > 0 { // cross into upper half
            state.ratchet = 1
            rl.PlaySound(sounds["ratchet_1.wav"])
            // TODO: play sound
        } else if old_diff.y > 0 && diff.y < 0 { // cross out of upper half
            if diff.x < 0 && state.ratchet == 1 {
                rl.PlaySound(sounds["ratchet_2.wav"])
                state.rotations += 1
            }
            state.ratchet = 0
        }

        //DrawRectanglePro(Rectangle{state.player[1].pos.x, state.player[1].pos.y, 10, 40}, rl.Vector2{10, 20}, angle * (180 / math.π), GREEN)
        //turret := state.player[1].pos + up * 10
        //DrawRectanglePro(Rectangle{turret.x, turret.y, 8, 30}, rl.Vector2{10, 25}, angle * (180 / math.π), GREEN)
        color := WHITE
        if is_limited(&damage_limiter) && i32(rl.GetTime() * 10) % 2 < 1 {
            color = rl.Color{255, 100, 100, 255}
        }
        draw_tex_rot(tank_tex, player.pos, angle + math.π / 2, 1.0, color)
        if jetblast {
            DrawTexturePro(jetblast_tex,
            Rectangle{0, 0, cast(f32) jetblast_tex.width, cast(f32) jetblast_tex.height * (-1 if (int(rl.GetTime() * 10) % 2 < 1) else 1)},
            Rectangle{player.pos.x, player.pos.y, cast(f32) jetblast_tex.width, cast(f32) jetblast_tex.height},
            Vector2{cast(f32) tank_tex.width / 2 - 64, cast(f32) tank_tex.height / 2 - 20},
            (angle + math.π / 2) * (180 / math.π),
            rl.WHITE)
        }
        when DEBUG {
            DrawCircleLines(cast(i32)player.pos.x, cast(i32)player.pos.y, PLAYER_RADIUS, PINK)
            DrawCircleLines(cast(i32)player.pos.x, cast(i32)player.pos.y, PLAYER_HURT_RADIUS, GREEN)
        }
    }

    for bullet_pos in state.bullet_pos {
        rl.DrawCircle(cast(i32)bullet_pos.x, cast(i32)bullet_pos.y, BULLET_RADIUS, BLACK)
    }


    for enemy_pos, i in state.enemy_pos {
        if state.enemy_radius[i] == 0 {
            continue
        }
        color := rl.WHITE
        if state.enemy_last_damage_time[i] != 0 && cast(f32) rl.GetTime() - state.enemy_last_damage_time[i] < 1 {
            if (int(rl.GetTime() * 10) % 2) < 1 {
                color = rl.RED
            }
        }
        levels[state.level].draw(state, i, color)

        when DEBUG {
            rl.DrawCircleLines(cast(i32) pos.x, cast(i32) pos.y, state.enemy_radius[i], rl.RED)
        }
    }

    // draw beam
    rl.DrawRectangleRec(Rectangle{x=state.beam.x - 10, y=state.beam.y - 10, width=1000, height=20}, GRAY)

    for impact in small_array.slice(&impacts) {
        frame_width := impact.tex.width / impact.frames
        frame := cast(i32) (impact.time / (impact.ttl / cast(f32) impact.frames))
        rl.DrawTexturePro(impact.tex^,
        Rectangle{cast(f32) frame_width * cast(f32) frame, 0, cast(f32) frame_width, cast(f32) impact.tex.height},
        Rectangle{impact.pos.x, impact.pos.y, cast(f32) frame_width, cast(f32) impact.tex.height},
        Vector2{cast(f32) frame_width / 2, cast(f32) impact.tex.height / 2},
        0,
        WHITE)
    }

    EndMode2D()

    switch state.game_state {
        case .Gameplay:
        if player, player_alive := state.player.(PlayerAlive); player_alive {
            rl.DrawRectangle(10, 10, cast(i32) player.health * 4, 10, rl.WHITE)
            rl.DrawText(fmt.ctprintf("Rotations %d", state.rotations), 20, 40, 40, rl.WHITE)
            all := true
            for r in state.enemy_radius {
                if r != 0 {
                    all = false
                    break
                }
            }
            if all {
                small_array.push(&impacts, Impact{
                    pos = state.enemy_pos[0],
                    ttl = 0.8,
                    tex = &boss_death_tex,
                    frames = 8,
                })
                state.game_state = levels[state.level].win_state
                rl.StopMusicStream(victory_music)
                rl.PlayMusicStream(victory_music)
                music = victory_music
                victory_time = rl.GetTime()
            }
        } else {
            state.game_state = .Lose
        }
        case .Victory:
        draw_text_centered("Mission Success\nPress [Space] to continue", 30)
        if rl.IsKeyReleased(.SPACE) {
            state.level += 1
            reset_level(&state)
        }
        case .Victory_Final:
        t := rl.GetTime() - victory_time
        if t < 6 {
            draw_text_centered("Mission Success", 70)
        } else if t < 12 {
            draw_text_centered("Built in 20 days for\nBoss Bash Jam 2023", 40)
        } else if t < 18 {
            draw_text_centered("Thanks for playing!", 70)
        }
        case .Lose:
        draw_text_centered("Mission Failed\nHit [R] to restart", 70)
        if rl.IsKeyReleased(.R) {
            reset_level(&state)
        }
    }
}


package main
import rl "raylib"
import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:math/noise"
import "core:encoding/json"
import "core:slice"

import "core:runtime"
import "core:container/small_array"

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
}

EnemyEvent :: enum {
    None,
    Damage,
    Died,
}

// TODO scenarios:
// tank vs small enemies, lead up to miniboss?

target_tex: rl.Texture
impact_tex: rl.Texture
powershield_impact: rl.Texture
tank_tex: rl.Texture
tank_hammer_tex: rl.Texture
sounds: map[string]rl.Sound
intro: rl.Music
songs: [3]rl.Music
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
general_tex: rl.Texture
bg: [3]rl.Texture
renderbuf: rl.RenderTexture2D
logo_tex: rl.Texture

state: State

// reset every frame
enemy_event: [40]EnemyEvent

frame_i := 0

DEBUG :: false

levels := [?]LevelProcs {
    {
        init = init_tutorial,
        update = update_tutorial,
        draw = draw_tutorial,
    },
    {
        init = init_level1,
        update = update_level1,
        draw = draw_level1,
    },
    {
        init = init_boss,
        update = update_boss,
        draw = draw_boss,
    }
}

PlayerAlive :: struct {
    pos: rl.Vector2,
    pos_old: rl.Vector2,
    health: f32,
    power_shield: f32,
}

PlayerDead :: struct {}

DamageMask :: enum {
    Bullet,
    Hit,
}

fade_to_black :: proc(state: ^State) -> bool {
    if state.fade < 1 {
        state.fade = math.min(state.fade + 0.05, 1)
        return false
    }
    return true
}

next_level :: proc(state: ^State) -> bool {
    state.level += 1
    reset_level(state)
    return true
}

PLAYER_RADIUS :: 32
PLAYER_HURT_RADIUS :: PLAYER_RADIUS * 0.55
BULLET_RADIUS :: 4
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

    bullet_pos: small_array.Small_Array(40, rl.Vector2),
    bullet_pos_old: small_array.Small_Array(40, rl.Vector2),

    beam: rl.Vector2,
    disable_beam: bool,

    enemy_pos: [40]rl.Vector2,
    enemy_pos_old: [40]rl.Vector2,
    enemy_radius: [40]f32,
    enemy_health: [40]f32,
    enemy_damage_mask: [40]bit_set[DamageMask],
    enemy_last_damage_time: [40]f32,

    boss_state_time: f32,
    boss_state: BossState,

    lines: []string,
    line_i: int,
    text_i: int,

    fade: f32,

    event_queue: []proc(^State) -> bool,
    tutorial_flag: int,
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

text_limiter := Limiter {
    cooldown = 0.05
}

Impact :: struct {
    pos: rl.Vector2,
    time: f32,
    ttl: f32,

    tex: ^rl.Texture,
    frames: i32,
}

impacts: small_array.Small_Array(20, Impact)

victory_time := 0.0

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
    rl.DrawText(text, WIDTH / 2 - cast(i32) s.x / 2, HEIGHT / 2 - cast(i32) s.y / 2 + 4, size, rl.BLACK)
    rl.DrawText(text, WIDTH / 2 - cast(i32) s.x / 2, HEIGHT / 2 - cast(i32) s.y / 2, size, rl.WHITE)
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

reset_level :: proc(state: ^State) -> bool {
    level := state.level
    if music.ctxData != songs[level].ctxData {
        rl.StopMusicStream(music)
        music = songs[level]
    }
    if !rl.IsAudioStreamPlaying(music) {
        rl.PlayMusicStream(music)
    }

    state^ = State{
        aim_assist = false,
        level = level,
        player = PlayerAlive{pos={600, 500}, pos_old={600, 500}, health=30},
        beam = {600, 300},
    }

    state.lines = {""}

    levels[state.level].init(state)

    return true
}

boss_lines := [?]string{
    "Oh. That's a big one",
    "Use your power armor to break his skull.",
}

BOSS_HEALTH :: 400

init_boss :: proc(state: ^State) {
    state.lines = boss_lines[:]
    state.aim_assist = true
    rl.PlayMusicStream(music)

    state.enemy_pos[0] = {-40, 400}
    state.enemy_pos_old[0] = state.enemy_pos[0]
    state.enemy_radius[0] = 50
    state.enemy_radius[1] = 20
    state.enemy_radius[2] = 20

    state.enemy_damage_mask[0] += {.Bullet}

    state.enemy_health[0] = BOSS_HEALTH
    state.enemy_health[1] = 80
    state.enemy_health[2] = 80
    state.boss_state_time = 2
}

update_boss :: proc(state: ^State, events: []EnemyEvent) {
    state.boss_state_time -= rl.GetFrameTime()
    player, alive := state.player.(PlayerAlive)

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

    if state.enemy_health[0] > 0 {
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
        update_hand(state.enemy_pos[0], rl.Vector2{1, 1.2}, &state.enemy_pos[1], state.boss_state)
        update_hand(state.enemy_pos[0], rl.Vector2{1, 2.5}, &state.enemy_pos[2], state.boss_state)
    } else if state.game_state != .Victory_Final {
        state.boss_state = .Idle
        small_array.push(&impacts, Impact{
            pos = state.enemy_pos[0],
            ttl = 0.8,
            tex = &boss_death_tex,
            frames = 8,
        })
        state.game_state = .Victory_Final
        rl.StopMusicStream(victory_music)
        rl.PlayMusicStream(victory_music)
        music = victory_music
        victory_time = rl.GetTime()
    }
}

draw_boss :: proc(state: State, i: int, color: rl.Color) {
    enemy_pos := state.enemy_pos[i]
    if i == 0 {
        rl.DrawRectangleV(enemy_pos + {-45, -70}, {BOSS_HEALTH / 5, 5}, rl.LIGHTGRAY)
        rl.DrawRectangleV(enemy_pos + {-45, -70}, {state.enemy_health[0]/ 5, 5}, rl.RED)
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

tutorial_lines_1 := [?]string{
    "Congratulations soldier, you've been selected to join our\nexperimental TANKERS force. [Left click to advance dialog]",
    "Some genius in a lab decided replacing ship artillery with\ntanks would simplify manufacturing",
    "You'll prove out the effectiveness of this\n<cough> terrible <cough> idea.",
    "Start with some target practice in your TH-0R.\nShoot the targets above you.",
    "[Left click to fire cannon]",
}

init_tutorial :: proc(state: ^State) {
    state.lines = tutorial_lines_1[:]
    state.disable_beam = true
    state.enemy_radius[0] = 20
    state.enemy_radius[1] = 20
    state.enemy_radius[2] = 20
    state.enemy_radius[3] = 20

    state.enemy_health[0] = 10
    state.enemy_health[1] = 10
    state.enemy_health[2] = 10
    state.enemy_health[3] = 30

    state.enemy_damage_mask[0] += {.Bullet}
    state.enemy_damage_mask[1] += {.Bullet}
    state.enemy_damage_mask[2] += {.Bullet}

    state.enemy_pos[0] = {-40, 0}
    state.enemy_pos[1] = {-40, 0}
    state.enemy_pos[2] = {-40, 0}
    state.enemy_pos[3] = {-40, 0}

}

tutorial_lines_2 := [?]string{
    "To counteract the force of cannon blasts, your tank has\nbeen equipped with a rocket engine",
    "[Right click and hold to fire rocket]",
    "Use it to line up your shots or slow the spin.",
}

tutorial_lines_3 := [?]string{
    "To improve mobility further, the crane enables lateral movement.",
    "[Horizontal mouse movement adjusts the beam position]",
}

tutorial_lines_4 := [?]string{
    "Lastly, your tank has been equipped with... <ahem> \"power armor\"\nthat can pulverize your opponents if you gain enough speed.",
    "Power it by completing a clockwise crank. The\nindicator in the top left will turn green when your armor is enabled.",
    "Use it to destroy the target that is impervious to bullets.",
    "Crank it to full power, then start blasting to get enough\nspeed to destroy the target.",
}

tutorial_lines_5 := [?]string{
    "Alright, soldier. Your training is complete.\nPrepare for combat.",
}

fade_to_next_level := [?](proc(^State) -> bool){fade_to_black, next_level}

update_tutorial :: proc(state: ^State, events: []EnemyEvent) {
    if state.tutorial_flag == 0 {
        state.enemy_pos[0] = {400, 30}
        state.enemy_pos[1] = {400, 80}

        if state.enemy_radius[0] == 0 && state.enemy_radius[1] == 0 {
            state.lines = tutorial_lines_2[:]
            state.line_i = 0
            state.text_i = 0
            state.tutorial_flag += 1
        }
    } else if state.tutorial_flag == 1 {
        if text_active(state^) {
            return
        }

        state.enemy_pos[2] = {200, 200}
        if state.enemy_radius[2] == 0 {
            state.lines = tutorial_lines_3[:]
            state.line_i = 0
            state.text_i = 0
            state.tutorial_flag += 1
            state.boss_state_time = cast(f32) rl.GetTime()
        }
    } else if state.tutorial_flag == 2 {
        if text_active(state^) {
            return
        }
        state.disable_beam = false

        if cast(f32) rl.GetTime() - state.boss_state_time > 10 {
            state.lines = tutorial_lines_4[:]
            state.line_i = 0
            state.text_i = 0
            state.tutorial_flag += 1
        }
    } else if state.tutorial_flag == 3 {
        state.enemy_pos[3] = {400, 300}
        if state.enemy_radius[3] == 0 {
            state.lines = tutorial_lines_5[:]
            state.line_i = 0
            state.text_i = 0
            state.tutorial_flag += 1
        }
    } else if state.tutorial_flag == 4 {
        if text_active(state^) {
            return
        }
        state.event_queue = fade_to_next_level[:]
        state.tutorial_flag += 1
    }
}

draw_tutorial :: proc(state: State, i: int, color: rl.Color) {
    c := color
    if i == 3 {
        c = rl.PURPLE
    }
    draw_tex(target_tex, state.enemy_pos[i], c)
}

level1_lines := [?]string{
    "We're being swarmed by unidentified attackers made of rock.",
    "Probably an idea from another genius in the lab.",
    "Take them out before they cause problems.",
}

init_level1 :: proc(state: ^State) {
    rl.PlayMusicStream(music)

    for i in 0..<40 {
        state.enemy_health[i] = 10
        state.enemy_radius[i] = 12
        x := rl.GetRandomValue(-40, 0)
        y := rl.GetRandomValue(0, 400)
        state.enemy_pos[i] = {cast(f32) x, cast(f32) y}
        state.enemy_damage_mask[i] += {.Bullet}
    }

    state.lines = level1_lines[:]
    state.boss_state_time = cast(f32) rl.GetTime()
}

update_level1 :: proc(state: ^State, events: []EnemyEvent) {
    for pos, i in state.enemy_pos {
        if state.enemy_radius[i] <= 0 {
            continue
        }

        target := rl.Vector2{1000, 400}
        if player, player_alive := state.player.(PlayerAlive); player_alive {
            if (cast(i32) rl.GetTime()) % 10 < 2 && cast(f32) rl.GetTime() - state.boss_state_time > 10 {
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

    all := true
    for r in state.enemy_radius {
        if r != 0 {
            all = false
            break
        }
    }
    if all && state.game_state != .Victory {
        state.game_state = .Victory
        rl.StopMusicStream(victory_music)
        rl.PlayMusicStream(victory_music)
        music = victory_music
        victory_time = rl.GetTime()
    }
}

draw_level1 :: proc(state: State, i: int, color: rl.Color) {
    draw_tex(enemy_tex, state.enemy_pos[i], color)
}

apply_bullet_damage :: proc(
    bullet_pos_arr: ^small_array.Small_Array(40, rl.Vector2),
    bullet_pos_old_arr: ^small_array.Small_Array(40, rl.Vector2),
    enemy_poss: []rl.Vector2,
    enemy_radius: []f32,
    enemy_damage_mask: []bit_set[DamageMask],
    enemy_health: []f32,
    enemy_event: []EnemyEvent, // out
) {
    for i := 0; i < small_array.len(bullet_pos_arr^); {
        bullet_pos := small_array.slice(bullet_pos_arr)
        bullet_pos_old := small_array.slice(bullet_pos_old_arr)
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
            small_array.unordered_remove(bullet_pos_arr, i)
            small_array.unordered_remove(bullet_pos_old_arr, i)
            continue
        } else {
            i += 1
        }
    }
}

text_active :: proc(state: State) -> bool {
    return state.line_i < len(state.lines)
}

WIDTH :: 800
HEIGHT :: 600

@export
init :: proc "c" () {
    rl.InitWindow(WIDTH, HEIGHT, "TANKERS")
    rl.InitAudioDevice()

    rl.SetTargetFPS(60);
    context = runtime.default_context()
    // NOTE: THIS IS NECESSARY FOR A LOT OF ODIN TYPES TO WORK
    #force_no_inline runtime._startup_runtime()

    victory_music = rl.LoadMusicStream("resources/tankers-victory.mp3")
    victory_music.looping = false
    rl.PlayMusicStream(victory_music)

    renderbuf = rl.LoadRenderTexture(WIDTH, HEIGHT)

    target_tex = rl.LoadTexture("resources/target.png")
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
    general_tex = rl.LoadTexture("resources/general.png")
    boss_death_tex = rl.LoadTexture("resources/boss-death.png")
    // TODO: parallax
    // TODO: birds
    bg = {
        rl.LoadTexture("resources/bg0.png"),
        rl.LoadTexture("resources/bg1.png"),
        rl.LoadTexture("resources/bg2.png"),
    }

    logo_tex = rl.LoadTexture("resources/logo.png")

    sounds = make(map[string]rl.Sound)
    impact_tex = rl.LoadTexture("resources/impact.png")
    powershield_impact = rl.LoadTexture("resources/powersheild-impact.png")
    tank_tex = rl.LoadTexture("resources/tank.png")
    tank_hammer_tex = rl.LoadTexture("resources/tank-hammer.png")
    //files, err := filepath.glob("resources/*.wav")
    //for soundpath in files {
        //sounds[filepath.base(soundpath)] = rl.LoadSound(strings.clone_to_cstring(soundpath))
    //}

    sounds["armor_powerup.wav"] = rl.LoadSound("resources/armor_powerup.wav")
    sounds["dirt_impact.wav"] = rl.LoadSound("resources/dirt_impact.wav")
    sounds["impact_heavy.wav"] = rl.LoadSound("resources/impact_heavy.wav")
    sounds["impact.wav"] = rl.LoadSound("resources/impact.wav")
    sounds["ratchet_1.wav"] = rl.LoadSound("resources/ratchet_1.wav")
    sounds["ratchet_2.wav"] = rl.LoadSound("resources/ratchet_2.wav")
    sounds["shot.wav"] = rl.LoadSound("resources/shot.wav")

    rl.SetSoundVolume(sounds["ratchet_1.wav"], 0.4)
    rl.SetSoundVolume(sounds["ratchet_2.wav"], 0.4)

    intro = rl.LoadMusicStream("resources/tankers-intro.mp3")
    rl.PlayMusicStream(intro)
    songs[0] = rl.LoadMusicStream("resources/tankers-combat.mp3")
    songs[1] = songs[0]
    songs[2] = rl.LoadMusicStream("resources/tankers.mp3")

    music = intro
}

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
        GRAVITY :: rl.Vector2{0,0.5}
        pos[i] += ((pos[i] - old_pos[i]) + GRAVITY) * damping
        old_pos[i] = tmp
    }
}

verlet_solve_constraints :: proc(root: rl.Vector2, child: ^rl.Vector2, dist: f32) {
    using linalg

    diff := child^ - root
    diff_len := vector_length(diff)
    if diff_len > dist {
        child^ = root + (diff / diff_len) * dist
    }
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

scale := 1

render_bg :: proc() {
    using rl
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
}

draw_renderbuf :: proc() {
    using rl
    if IsKeyReleased(.ONE) {
        scale = 1
        SetWindowSize(cast(i32) (WIDTH*scale), cast(i32) (HEIGHT*scale))
    } else if IsKeyReleased(.TWO) {
        scale = 2
        SetWindowSize(cast(i32) (WIDTH*scale), cast(i32) (HEIGHT*scale))
    }

    BeginDrawing()

    r := Rectangle{0, 0, 800, -600}
    DrawTexturePro(renderbuf.texture,
    r,
    Rectangle{0, 0, cast(f32) rl.GetScreenWidth(), cast(f32) rl.GetScreenHeight()},
    {0, 0},
    0,
    rl.WHITE)

    when DEBUG {
        rl.DrawFPS(10, 10)
    }
    EndDrawing()
}

do_intro := true
update_intro :: proc() {
    using rl
    UpdateMusicStream(music)

    if IsMouseButtonReleased(.LEFT) {
        do_intro = false
        reset_level(&state)
    }

    BeginTextureMode(renderbuf);
    render_bg()
    rl.DrawTexturePro(
        logo_tex,
        rl.Rectangle{0, 0, cast(f32) logo_tex.width, cast(f32) logo_tex.height},
        rl.Rectangle{
            f32(WIDTH / 2 - logo_tex.width),
            f32(HEIGHT / 2 - logo_tex.height),
            f32(logo_tex.width * 2),
            f32(logo_tex.height * 2),
        },
        {0, 0},
        0,
        rl.WHITE
    )

    {
        {
            text: cstring = "[Left click] to start"
            size: i32 = 30
            spacing := size / 10
            s := rl.MeasureTextEx(rl.GetFontDefault(), text, cast(f32) size, cast(f32) spacing)
            rl.DrawText(text, WIDTH / 2 - cast(i32) s.x / 2, HEIGHT / 2 - cast(i32) s.y / 2 + 140, size, rl.BLACK)
        }

        {
            text: cstring = "Choose pixel art scale with [1] and [2]"
            size: i32 = 20
            spacing := size / 10
            s := rl.MeasureTextEx(rl.GetFontDefault(), text, cast(f32) size, cast(f32) spacing)
            rl.DrawText(text, WIDTH / 2 - cast(i32) s.x / 2, HEIGHT / 2 - cast(i32) s.y / 2 + 165, size, rl.BLACK)
        }
    }

    EndTextureMode()
    draw_renderbuf()
}

to_cstring :: proc(str: string, buf: []byte) -> cstring {
    assert(len(buf) > len(str) + 1)
    copy(buf, str)
    buf[len(str)] = 0
    return cstring(rawptr(&buf[0]))
}

@export
update :: proc "c" () {
    using rl
    context = runtime.default_context()
    if do_intro {
        update_intro()
        return
    }

    BeginTextureMode(renderbuf);
    rl.UpdateMusicStream(music)

    render_bg()

    // frame vars
    jetblast := false
    for _, i in enemy_event {
        enemy_event[i] = .None
    }

    when DEBUG {
        if rl.IsKeyReleased(.LEFT_BRACKET) {
            state.level -= 1
            state.event_queue = {fade_to_black, reset_level}
        }

        if rl.IsKeyReleased(.RIGHT_BRACKET) {
            state.level += 1
            state.event_queue = {fade_to_black, reset_level}
        }
    }

    { // logic/physics
        if(!update_stunned(&hitstop)) {
            verlet_integrate(
                small_array.slice(&state.bullet_pos),
                small_array.slice(&state.bullet_pos_old))
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
                if !state.disable_beam {
                    state.beam.x += math.clamp((cast(f32) GetMouseX() / cast(f32) scale) - state.beam.x, -4, 4)
                    state.beam.x = clamp(state.beam.x, 400, 800)
                }
                switch player in &state.player {
                    case PlayerAlive:
                    if !text_active(state) && IsMouseButtonReleased(.LEFT) {
                        left := vec_ccw(vec_up(state.beam, player.pos))
                        // give it a force from the right
                        player.pos_old += left * 40

                        rl.PlaySound(sounds["shot.wav"])

                        if state.aim_assist && player.power_shield == 0 {
                            ideal := linalg.normalize(state.enemy_pos[0] + {0, -20} - player.pos)
                            d := linalg.dot(ideal, left)
                            if 0.8 < d && d < 1 {
                                when DEBUG {
                                    rl.TraceLog(.INFO, "aim assist %f", cast(f64) linalg.dot(ideal, left))
                                }
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

                        small_array.append(&state.bullet_pos, bullet_pos)
                        small_array.append(&state.bullet_pos_old, bullet_pos_old)
                    }

                    if IsMouseButtonDown(.RIGHT) {
                        jetblast = true
                        right := -vec_ccw(vec_up(state.beam, player.pos))
                        player.pos_old += right * 0.8
                    }

                    verlet_integrate(slice.from_ptr(&player.pos, 1), slice.from_ptr(&player.pos_old, 1))
                    for i in 0..<10 {
                        PLAYER_MAX_DIST :: 200.0
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
                    if linalg.vector_length(v) > 30 && player.power_shield > 0 {
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
    if player, player_alive := &state.player.(PlayerAlive); player_alive { // draw player
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

        ROTATION_POWER_FACTOR :: 1
        if state.rotations == 10 {
            player.power_shield = cast(f32) state.rotations * ROTATION_POWER_FACTOR
            state.rotations = 0
            stun(&hitstop, 0.4)
            shake_magnitude = 4

            rl.PlaySound(sounds["armor_powerup.wav"])

            small_array.push(&impacts, Impact{
                pos = player.pos,
                ttl = 0.5,
                tex = &powershield_impact,
                frames = 5,
            })
        }
        player.power_shield = math.max(0, player.power_shield - rl.GetFrameTime())

        color := WHITE
        if is_limited(&damage_limiter) && i32(rl.GetTime() * 10) % 2 < 1 {
            // RED
            color = rl.Color{255, 100, 100, 255}
        }
        if player.power_shield > 0 {
            tex := tank_hammer_tex
            DrawTexturePro(tex,
            Rectangle{0, 0, cast(f32) tex.width, cast(f32) tex.height},
            Rectangle{player.pos.x, player.pos.y, cast(f32) tex.width, cast(f32) tex.height},
            Vector2{cast(f32) tex.width / 2, cast(f32) tex.height / 2 + 13},
            (angle + math.π / 2) * (180 / math.π),
            color)
        } else {
            draw_tex_rot(tank_tex, player.pos, angle + math.π / 2, 1.0, color)
        }
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

    for bullet_pos in small_array.slice(&state.bullet_pos) {
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
            rl.DrawCircleLines(cast(i32) enemy_pos.x, cast(i32) enemy_pos.y, state.enemy_radius[i], rl.RED)
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
            BAR_SCALE_FACTOR :: 4
            if player.power_shield == 0 {
                rl.DrawRectangle(10, 30, cast(i32) state.rotations * BAR_SCALE_FACTOR, 10, rl.GRAY)
            } else {
                rl.DrawRectangle(10, 30, cast(i32) (player.power_shield * BAR_SCALE_FACTOR), 10, rl.GREEN)
            }

            if text_active(state) {
                // textbox
                bg_rec := rl.Rectangle{
                    x = cast(f32) WIDTH / 2 - 200,
                    y = cast(f32) HEIGHT - 48,
                    width = 400,
                    height = 48,
                }
                rl.DrawRectangleRec(bg_rec, rl.LIGHTGRAY)

                GENERAL_FRAMES :: 2
                frame_width := cast(f32) general_tex.width / GENERAL_FRAMES
                frame := 1 if ((cast(int) (rl.GetTime() * 1000)) % 2000) < 100 else 0

                portrait_rec := Rectangle{bg_rec.x, bg_rec.y, frame_width, cast(f32) general_tex.height}
                rl.DrawRectangleRec(portrait_rec, LIGHTGRAY)
                rl.DrawTexturePro(general_tex,
                Rectangle{cast(f32) frame_width * cast(f32) frame, 0, cast(f32) frame_width, cast(f32) general_tex.height},
                portrait_rec,
                Vector2{0, 0},
                0,
                WHITE)

                buf: [256]u8
                rl.DrawText(to_cstring(state.lines[state.line_i][:state.text_i], buf[:]),
                    cast(i32) bg_rec.x + 48 + 5,
                    cast(i32) bg_rec.y + 5,
                    10,
                    rl.BLACK)

                if state.text_i < len(state.lines[state.line_i]) {
                    if trigger(&text_limiter) {
                        state.text_i += 1
                    }
                    if rl.IsMouseButtonReleased(.LEFT) {
                        state.text_i = len(state.lines[state.line_i])
                    }
                } else {
                    if rl.IsMouseButtonReleased(.LEFT) {
                        state.line_i += 1
                        state.text_i = 0
                    }
                }
            }
        } else {
            state.game_state = .Lose
        }
        case .Victory:
        draw_text_centered("Mission Success\nPress [Space] to continue", 30)
        if rl.IsKeyReleased(.SPACE) {
            state.event_queue = fade_to_next_level[:]
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
            state.event_queue = {fade_to_black, reset_level}
        }
    }
    frame_i += 1
    rl.DrawRectangle(0, 0, WIDTH, HEIGHT, rl.Fade(rl.BLACK, state.fade))

    if len(state.event_queue) > 0 {
        done := state.event_queue[0](&state)
        if done && len(state.event_queue) > 0 {
            state.event_queue = state.event_queue[1:]
        }
    }

    EndTextureMode();
    draw_renderbuf()
}


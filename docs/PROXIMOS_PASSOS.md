# SWMP — estado e próximos passos (atualizado 20/10/2026)

## Funciona (testado no jogo real, mod v0.16)
- **Trilha sonora no jogo**: o portal exporta músicas (OGG/Opus → MP3 no browser, `vendor/lame.min.js` com SRI) para
  `Scripts\swmp_music\` + `mp_playlist.json`; o mod arranca `swmp_player.ps1` ao abrir o jogo (relança-se pelo WMI —
  o jogo mata processos filhos ao carregar mapas), troca música por cena/faixa, silencia a original só com o leitor vivo.
- **Estabilidade**: crashes 0x18 corrigidos (GetFName em objeto nulo no 1.º instante do combate); todo o trabalho com
  objetos do jogo corre via `ExecuteInGameThread`; 6 s de pausa no início do combate.
- **Batalha Rápida**: portal /coop → `mp_qb_cmd.json` → mod usa o lançamento de testes dos programadores
  (`B_QuickLaunchViewModel` + `BRG_MissionTestingSettings`, 86 mundos: 44 escaramuças, 11 herói, 11 história).
  Ryloth 010 testado: carrega direto no combate.
- **Batalha 1x1 (interface nativa para os dois)**: `BP_PlayerTurnGroup` também no lugar do `BP_AITurnGroup` em
  `TurnGroupSubsystem.OrderedTurnGroups`; gancho em `BP_BrunoGameplayMaster_C:RequestEndTurn` troca todas as unidades
  de equipa com `BitReactorGameStatics_Unit:ChangeActorTeam` (PlayerTeam_C ↔ EnemyTeam_C). Ciclo J1 → J2 → J1
  testado, rondas e objetivos contam certo. Câmara roda 180° (injeção de `IA_RotateCamera`) para cada um ver por trás
  das suas unidades.
- **Só jogo original**: SWMP-Host e mod verificam manifesto Steam, assinatura Valve da steam_api64.dll, sem crack.

## Bugs conhecidos (por ordem)
1. ~~Seleção ao passar a vez~~ — RESOLVIDO v0.17 (testado 21/10 em Ryloth 010): `pvp_select_side` repete
   `SelectNextCharacter()` até `GetSelectedCharacter()` ser do PlayerTeam; J1→J2 seleciona B1_C_0, J2→J1 seleciona HAWKS.
2. ~~VIPs na troca~~ — v0.17: `Char_VIP*` fora de `pvp_swap`. Em Ryloth 010 os `Char_VIP_Civilian_Captured_*` são
   CivilianTeam e ficam fora da troca (J2 = 12 B1, J1 = 4 heróis).
3. ~~Missões com temporizador~~ — RESOLVIDO v0.18 (testado 21/10 em Ryloth 010): a cada troca de vez
   `pvp_hold_timers` repõe `BRGameTacticalTimer.DurationRemaining` = `DurationToCount` (mín. 2); ficou 4/4 e 6/6
   após 3 fins de vez. Objetivos de resgate/evacuação continuam ativos (o J1 ainda pode ganhar evacuando).
4. Ao reabrir, o jogo às vezes retoma direto a última missão (sem passar pelo menu) — a Batalha Rápida só funciona
   a partir do menu principal (`qb_vm` só existe lá).

## Próximos passos (pedidos do Marco)
1. **Mecânica justa no 1x1**: escolher qual inimigo atacar, % de acerto com cobertura/objetos, pré-visualização de dano,
   linhas de visão — tudo do lado do J2 igual ao J1. Como o J2 usa o grupo de turno do jogador e as unidades são
   PlayerTeam durante a vez dele, a mira nativa já deve calcular cobertura e % — **verificar** com um ataque real
   (tecla 2 → hover num herói → ver % e cobertura; ver também `UBRG_TargetedActorVM`). Confirmar também o
   "overwatch/reação" do lado que não está a jogar.
2. **Modo batalha** — FEITO v0.19 (testado 21/10, Ryloth 010, 4x4): no portal, com 1x1 marcado, cada jogador escolhe
   até 4 personagens (Equipa A/B). `mp_qb_cmd.json` leva `squad` (A depois B, caminhos de classe) + `team_b`; o mod
   escreve `BRG_MissionTestingSettings.DefaultMissionSquad`, e no combate (`qb_battle_setup`) teleporta a B para as
   posições dos inimigos do mapa (`BitReactorGameStatics_Unit:TeleportActor`, tenta o ponto seguinte se devolver false),
   remove esses inimigos (`K2_DestroyActor`, estável) e passa a B a EnemyTeam. Falta: lista de personagens só tem os 8
   conhecidos (`QB_HEROES` no index.html) — descobrir o roster completo; só há 4 pontos de entrada da equipa A
   (mais de 4 ficam empilhados); posições aleatórias; testar noutros mapas.
3. **Co-op (modo história)**: cada um escolhe 3 personagens; mesmo turno do jogador dividido (J1 joga os seus 3,
   depois o J2 os seus 3) contra a IA. **Requisito do Marco: dois ecrãs/jogos separados** (cada um no seu PC com o
   seu jogo original, só vê as suas unidades). Isto exige sincronizar dois jogos (lockstep: replicar cada ação —
   habilidade + alvo + resultado — pelo SWMP-Host/relay, e alinhar o RNG/resultado de acertos). É o maior trabalho;
   começar por prova de conceito: replicar um movimento de uma unidade entre dois PCs.
4. Radial ou barra reta: a opção "Estilo de Seleção de Habilidade" do jogo — testar o J2 com as duas.

## Ferramentas de desenvolvimento (PC do Marco)
- Mod `SWMPDev` (ue4ss\Mods\SWMPDev): corre Lua escrito em `dev_in.lua`, resposta em `dev_out.txt`.
- Sondas em `tools/quickbattle_probe*.lua`. **Regra**: nunca chamar métodos em objeto nulo (`GetClass`,
  `GetFName`, `GetMetaClass`…) — a UE4SS crasha e o pcall não apanha. Usar só unidades com `:PersistentLevel.` no nome.
- Crash reports do jogo: `%LOCALAPPDATA%\SWZeroCompany\Saved\Crashes\*\CrashContext.runtime-xml` (pilha legível).

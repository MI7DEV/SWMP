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
1. **Seleção ao passar a vez**: `SelectNextCharacter()` às vezes não seleciona a unidade do novo lado (radial fica no
   herói do J1, agora inimigo). Com TAB manual funciona. Tentar: chamar depois da câmara rodar, repetir até
   `GetSelectedCharacter()` ser do PlayerTeam, ou injetar a ação de TAB (procurar `IA_*SelectNext*`).
2. VIPs/unidades capturadas entram na troca de equipa (são PlayerTeam): no 1x1 excluir quem tem estado
   "capturado"/VIP (`Char_VIP_*`), senão aparecem na barra do J2.
3. Missões com temporizador (resgate em Ryloth) acabam o 1x1 — para o modo batalha escolher mapas/objetivo
   "derrotar todos" ou desligar objetivos.
4. Ao reabrir, o jogo às vezes retoma direto a última missão (sem passar pelo menu) — a Batalha Rápida só funciona
   a partir do menu principal (`qb_vm` só existe lá).

## Próximos passos (pedidos do Marco)
1. **Mecânica justa no 1x1**: escolher qual inimigo atacar, % de acerto com cobertura/objetos, pré-visualização de dano,
   linhas de visão — tudo do lado do J2 igual ao J1. Como o J2 usa o grupo de turno do jogador e as unidades são
   PlayerTeam durante a vez dele, a mira nativa já deve calcular cobertura e % — **verificar** com um ataque real
   (tecla 2 → hover num herói → ver % e cobertura; ver também `UBRG_TargetedActorVM`). Confirmar também o
   "overwatch/reação" do lado que não está a jogar.
2. **Modo batalha completo**: 6 unidades por jogador escolhidas no portal, mapa aleatório (lista `mp_qb_worlds.json`,
   categoria `Missions.Skirmishes`) e posições aleatórias (teleportar unidades para pontos navegáveis no início).
   O esquadrão do J1 pode usar `B_QuickLaunchViewModel:AddCharacterToSquad(SoftClass)`; o do J2 precisa de spawn de
   personagens (procurar spawners: `MissionStartSpawnerConfigs`, `GetSpawnSetForMission`, `BRActorSpawner`).
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

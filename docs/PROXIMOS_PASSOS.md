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
4. Ao reabrir, o jogo às vezes retoma direto a última missão (acontece quando o jogo é fechado a meio de um combate;
   sair: `PlayerController:ClientReturnToMainMenuWithTextReason`) (sem passar pelo menu) — a Batalha Rápida só funciona
   a partir do menu principal (`qb_vm` só existe lá).

## Próximos passos (pedidos do Marco)
1. **Mecânica justa no 1x1**: escolher qual inimigo atacar, % de acerto com cobertura/objetos, pré-visualização de dano,
   linhas de visão — tudo do lado do J2 igual ao J1. Como o J2 usa o grupo de turno do jogador e as unidades são
   PlayerTeam durante a vez dele, a mira nativa já deve calcular cobertura e % — **verificar** com um ataque real
   (tecla 2 → hover num herói → ver % e cobertura; ver também `UBRG_TargetedActorVM`). Confirmar também o
   "overwatch/reação" do lado que não está a jogar.
2. **Modo batalha** — FEITO v0.20 (testado 21/10, Ryloth 010, até 8x8): no portal, com 1x1 marcado, lista de TODAS
   as unidades (o mod grava `mp_units.json` a partir do registo de assets `/Game/Game/Core/Pawns`: heróis, campanha,
   inimigos por facção), filtro por texto/grupo, +A/+B e quantas de cada. LANÇAR escreve `mp_qb_cmd.json`
   (`squad` = A depois B, `team_b`) e abre o jogo pela Steam; o mod espera até 5 min pelo menu principal e lança.
   No combate (`qb_battle_setup`): B vai para as posições dos inimigos do mapa (`TeleportActor`), esses inimigos saem
   (`K2_DestroyActor`), B passa a EnemyTeam; `qb_spread` espalha as unidades empilhadas (anéis de 150 uu), com 2.ª
   passagem aos 4 s (o jogo repõe os pontos de entrada logo no início). Unidades inimigas (B1, Droideka, clones…)
   funcionam no esquadrão e o J2 controla-as com a interface nativa. Falta: testar noutros mapas e bosses.
3. **Co-op por Remote Play — FEITO v0.21 (testado 21/10 em Ryloth 010, um PC):** portal "Co-op — modo história"
   (LIGAR/DESLIGAR + J1/J2 por personagem) ou F9. `coop_turn_order` mete um 2.º BP_PlayerTurnGroup logo a seguir ao
   1.º em OrderedTurnGroups (6→7 grupos): ronda = vez do J1 → vez do J2 → civis → IA. Gancho RequestEndTurn alterna a
   vez; `coop_poll` (1 s) tira a seleção de personagens do outro (SelectNextCharacter até ser do dono da vez).
   Temporizadores: +1 ao fim da vez do J1 (a vez extra desconta). Estado/donos em mp_coop.json. Por ver: recargas e
   efeitos que contam por turno de equipa podem andar 2x por ronda; testar numa missão da campanha real.
   **Co-op em dois PCs — BETA v0.22 (21/10), por testar entre duas casas:**
   - Portal (index.html, secção "Co-op em 2 PCs"): PeerJS 1.5.4 (vendor/peerjs.min.js com SRI), código de sessão
     `swmp-coop-XXXXXX`; ponte mod↔rede por ficheiros mp_net_cmd/out/in.json (testado entre 2 separadores: mensagens
     nos dois sentidos, sem reenviar antigas, save de 3 MB inteiro). Envio de save: anfitrião lê SaveGames (*.sav), o
     convidado faz cópia `swmp_backup_<data>` e grava (do mais antigo ao mais recente → "Continuar" pega no do host).
   - Mod (`net_*`): HOST corre o co-op (vez J1/J2), recebe {t=act} e repete: movimento = TeleportActor (TESTADO);
     habilidade = TryActivatePlannedAbility + IA_ConfirmTarget (TESTADO: dispara/gasta PA). Manda {t=snap} 4 s depois de
     cada habilidade paga e no fim de cada vez (TESTADO: IA joga, ronda 2 começa, snaps continuam).
     CONVIDADO: sem IA local (grupo IA→jogador), IncomingDamageMultiplier=0, aplica snaps (TESTADO: mover, vida,
     remover mortos). Captura: `HandleAbilityActivated` = escolha (ex. GA_StandardShot_Longarm_C) +
     `HandleAbilityCommitted` = paga (alvo em `TargetActor`, ex. GA_PFAShot_*), só se gastou PA; movimento quando parou.
   - POR RESOLVER: a mira do host abre no alvo por omissão; `SetSuggestedTarget`/`SetAITargetingDataOverride` não a
     mudam; `GetSuggestedTarget()` dá o alvo da mira aberta só uns frames depois; trocar com TriggerNextTarget /
     IA_SelectNextTarget(_OTS) não foi validado (o Luco só tinha 1 alvo). O log mostra "mira de X passo N: alvo" e
     "AVISO alvo ... disparou em ..." — ver no 1.º teste real. Habilidades com alvo de posição (granadas) ainda não.
   - Testes: no SWMPDev o estado entre execuções só em `_G`; simular cliques é instável (mira presa → IA_CancelTarget).
   **Notas da investigação (21/10):**

3. **Co-op (modo história)**: cada um escolhe 3 personagens; mesmo turno do jogador dividido (J1 joga os seus 3,
   depois o J2 os seus 3) contra a IA. **Requisito do Marco: dois ecrãs/jogos separados** (cada um no seu PC com o
   seu jogo original, só vê as suas unidades). Isto exige sincronizar dois jogos (lockstep: replicar cada ação —
   habilidade + alvo + resultado — pelo SWMP-Host/relay, e alinhar o RNG/resultado de acertos). É o maior trabalho;
   começar por prova de conceito: replicar um movimento de uma unidade entre dois PCs.
   **Estado 21/10 (etapa 1 — capturar/reproduzir ações, num só PC):**
   - O que existia NÃO era co-op: o mod só envia TURN_STATE informativo (`mp_sync_out.json`) e o SWMP-Host (server.py,
     relay WebSocket + túnel Cloudflare) só reencaminha; nenhuma ação é replicada.
   - Dinâmica combinada com o Marco: portal Host/Cliente → fora do combate só o host joga a história livre (cliente
     espectador); antes de cada missão o save do host vai para o cliente; na preparação escolhe-se quem controla cada
     personagem; no combate cada um joga os seus e as ações são replicadas, com o host autoritativo (o cliente é
     corrigido com vida/posições/mortos); a IA corre no host.
   - CAPTURA funciona: `RegisterHook` em `BitReactorAbilitySystemComponent:HandleAbilityActivated/HandleAbilityCommitted`
     (args: ctx = ASC, 1.º = UGameplayAbility) e em `GameplayAbility:K2_CommitAbility/K2_EndAbility` disparam para
     cada habilidade (testado: GA_TeamTurnEnd_C, GA_TacticalEncounterEnded_C por unidade).
   - **CRASH**: iterar propriedades da habilidade (ForEachProperty + leitura) DENTRO do hook HandleAbilityCommitted
     crasha (0x18). No hook só ler classe + dono; inspeção pesada fora do hook (guardar nome e inspecionar depois) ou
     com o jogo parado.
   - REPRODUÇÃO (por testar): `BitReactorAbilitySystemComponent:SetAITargetingDataOverride(handle)` +
     `TryActivatePlannedAbility(ability, source)` é o caminho da IA; RNG do jogo: `BitReactorRandomStatics` (geradores
     com semente).
   - SWMPDev: cada execução tem ambiente próprio — estado entre execuções só em `_G.X`.
   - VIDA: `u.AbilitySystemComponent.SpawnedAttributes` → `BitReactorHealthSet.Health` (BaseValue/CurrentValue)
     lê e escreve bem (testado). MAS pôr 0 não mata; `GE_FixedDamage` (exec `BitReactorDamageDealtExecution`, tag
     `SetByCaller.Effect.PrimaryMagnitude`) via MakeOutgoingSpec+AssignTagSetByCallerMagnitude+ApplySpecToSelf não
     causou dano; `GameplayStatics:ApplyDamage` também não. Falta descobrir como matar uma unidade "a sério" (para o
     host aplicar mortes vindas do cliente) — ou reproduzir a habilidade do cliente no host (host decide tudo).
   - Ponte entre PCs: o client.html não escreve no jogo do convidado. Plano: o próprio portal (já tem acesso à pasta
     de mods em cada PC) faz a ponte mod↔rede, ligando os dois portais por WebRTC (PeerJS) com código de sessão.
   - Plano de reprodução (host decide tudo): cliente captura no K2_EndAbility da sua unidade a classe + posição final
     + alvo (ler do `BRG_TargetedActorVM` no commit); host: movimento = TeleportActor; ataque =
     `GetAbilitySpecHandleFromClass` + `SetAITargetingDataOverride(AbilityTargetDataFromActor(alvo))` +
     `TryActivatePlannedAbility`; depois o host manda o estado (vida/posições/mortos) e o cliente corrige.
   - Modo batalha: desligar o 1x1 (F8) a meio termina o combate (`GA_TacticalEncounterEnded`) — os inimigos do mapa
     foram removidos.
4. Radial ou barra reta: a opção "Estilo de Seleção de Habilidade" do jogo — testar o J2 com as duas.

## Ferramentas de desenvolvimento (PC do Marco)
- Mod `SWMPDev` (ue4ss\Mods\SWMPDev): corre Lua escrito em `dev_in.lua`, resposta em `dev_out.txt`.
- Sondas em `tools/quickbattle_probe*.lua`. **Regra**: nunca chamar métodos em objeto nulo (`GetClass`,
  `GetFName`, `GetMetaClass`…) — a UE4SS crasha e o pcall não apanha. Usar só unidades com `:PersistentLevel.` no nome.
- Crash reports do jogo: `%LOCALAPPDATA%\SWZeroCompany\Saved\Crashes\*\CrashContext.runtime-xml` (pilha legível).

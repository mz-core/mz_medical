# Fluxo médico autoritativo — Lote 5

## Arquitetura e autoridade

`mz_medical` coordena apresentação, pedidos de ajuda, atendimento e respawn hospitalar. Ele não mantém uma segunda verdade de vida/morte: `mz_core` continua sendo a única autoridade para `deathState`, vitais, revisão, sessão, transições e spawn físico autorizado. `mz_inventory` fornece a transação de reserva/commit/rollback do item; `mz_progress` apresenta o atendimento; `mz_hud` apenas renderiza; `mz_admin` apenas aciona exports fechados de recuperação.

O fluxo usa os estados canônicos `alive -> downed -> dead -> respawning -> alive`. Revive permitido por padrão é somente `downed -> alive`. Revive de `dead` permanece desligado. As mudanças críticas persistem antes de produzir o efeito observável; `persistence_pending` nunca autoriza um segundo efeito.

## Deadlines, scheduler, reconnect e restart

`downedExpiresAt` e `respawnAvailableAt` são epoch seconds persistidos na metadata do core. A primeira atribuição compatível vence e não é renovada por reconnect, resync ou repetição do evento. Um único scheduler server-side, com orçamento configurável por tick, expira downed para dead e fiscaliza atendimentos/respawns; não há thread por jogador.

No reconnect, o resource lê o estado e os deadlines persistidos. No restart de `mz_medical`, as operações efêmeras são canceladas, reservas são devolvidas e jogadores não são revividos. Um `respawning` órfão retorna de forma explícita a `dead`. No restart do core, dependentes precisam ser validados em runtime; não existe revive automático.

## Apresentação client

O client deriva tudo do sync canônico e rejeita revisão/sessão antigas. Em `downed`, aplica animação com timeout de carregamento e revalidação periódica; em `dead` e `respawning`, limpa a animação. Controles de combate, movimento e interações são bloqueados apenas enquanto não-alive. `H` solicita ajuda e `E` solicita respawn quando liberado. O HUD recebe apenas estado e segundos restantes. O resource médico não chama `NetworkResurrectLocalPlayer`, `SetEntityHealth` ou `SetPedArmour`.

## Pedido de ajuda

`mz_medical:server:requestHelp` tem schema fechado, source implícito, janela global, cooldown por sessão e aceita somente downed/dead. Coordenadas do client não são autoridade; quando disponíveis, as coordenadas server-side podem entrar no log. O MVP registra a solicitação e confirma ao solicitante, sem implementar dispatch completo.

## Atendimento e autorização profissional

O comando `/treat` envia apenas o server ID candidato mais próximo. O servidor recalcula existência, bucket, distância de início e distância de conclusão. O executor precisa estar alive, em duty na organização `ambulance`, grade mínima 2 e com capability `ambulance.revive.basic`. O alvo deve estar downed; ambos têm lock exclusivo e cooldown.

O item padrão é `firstaid`. O servidor reserva exatamente uma unidade/instância no inventário oficial e cria `operationId` e token opaco de alta entropia ligados a source, citizen ID, sessão, target, revisão inicial e prazo. O progress de 10 segundos é apresentação: conclusão client é apenas candidato. Cancelamento, afastamento, mudança de estado/revisão, troca de sessão, disconnect ou timeout cancelam a operação e fazem rollback.

`bandage` permanece um consumível de sobrevivência e não revive. `firstaid` representa o medkit básico deste MVP. Não foi criado desfibrilador: como revive de `dead` está desabilitado, expor esse item sugeriria um fluxo inexistente e inseguro.

## Reserva, commit, rollback e idempotência

A reserva vive no serviço de inventário do core, sob o mesmo lock da mochila. Guarda slot, amount/instância, metadata, citizen ID, sessão, contexto e deadline. Commit remove definitivamente a reserva; cancel devolve o stack/row exato, usando o slot original quando seguro ou um slot livre sem sobrescrever item concorrente.

O revive usa `expectedRevision` no core. Só depois da transição autoritativa o item é commitado. Se o efeito já foi confirmado, retries não repetem revive nem devolvem item grátis; falha de persistência do commit fica observável e é retentada. Operações terminais ficam retidas por janela limitada para respostas idempotentes. Dois médicos não obtêm lock do mesmo alvo.

Enquanto a reserva estiver ativa, outras mutações na mochila principal são recusadas com `medical_reservation_active`. Falha transitória ao devolver o item entra em `rollback_pending` e o scheduler retenta; o rollback procura a instância original e nunca sobrescreve um slot ocupado.

## Revive

Por padrão, somente `downed -> alive` é aceito. O core valida writer, sessão/revisão, estado e aplica health 100/armor 0 configurados pelo servidor. A aplicação física continua exclusivamente em `mz_core/client/player_state.lua`, via sync canônico. `dead` retorna `dead_revive_disabled` enquanto a política estiver desligada.

## Respawn hospitalar

Após `respawnAvailableAt`, um morto pode pedir respawn. O servidor escolhe o hospital Pillbox configurado, cria operação fechada, chama `BeginPlayerRespawn` com revisão esperada e pede ao core um spawn autorizado. O core escolhe o modelo canônico da aparência e encaminha coordenadas server-owned ao `spawnmanager`.

O client só reconhece o callback local autorizado e responde com `operationId` e token. O servidor revalida source, citizen ID, sessão, operação, estado, revisão e timeout antes de `CompletePlayerRespawn`; health final é 200 e armor 0. Falta de acknowledgment, disconnect ou restart aborta para `dead`, preservando o episódio e permitindo recuperação administrativa.

## Cobrança, perda de itens e voz

Cobrança hospitalar começa `enabled=false` e política gratuita; nenhuma fee do client é aceita. Perda de itens começa `mode='none'`; por isso não há remoção nem compensação financeira no MVP. Quando essas features forem habilitadas, exigirão adaptador idempotente e rollback comprovado antes do efeito final. Voz não é alterada neste lote.

## APIs e eventos

Exports do core usados: `GetPlayerState`, `GetPlayerStateIdentity`, `SetPlayerDeathDeadline`, `RevivePlayer`, `BeginPlayerRespawn`, `CompletePlayerRespawn`, `AbortPlayerRespawn`, `SpawnPlayerForMedical`, `ReserveMedicalItem`, `CommitMedicalItemReservation` e `CancelMedicalItemReservation`. Writers mutáveis são allowlisted para `mz_medical`; spawn médico e envelope client também conferem o invoking resource.

Eventos client→server: `requestHelp`, `startTreatment`, `completeTreatment`, `cancelTreatment`, `requestRespawn` e `ackRespawn`. Todos têm schema fechado, source implícito, janela de rate limit e validação contextual. Eventos server→client carregam apenas apresentação/operação (`helpResult`, `treatmentProgress`, `treatmentResult`, `respawnResult`). O evento interno de mudança de death state não é interface de rede.

Exports de `mz_medical`: `GetMedicalState` é leitura; `RecoverPlayer` e `CancelPlayerMedicalOperation` aceitam somente `mz_admin`. Recuperação administrativa usa as mesmas transições do core e nunca natives client-side.

## Segurança e observabilidade

São recusados target arbitrário/distante, buckets diferentes, coords/fee client-side, operação/token repetido, sessão antiga, revisão divergente, conclusão precoce e source reutilizado. As rejeições têm códigos estáveis e logs estruturados com operation ID, source/target, citizen ID quando disponível, estado e reason; dados sensíveis não são enviados ao client.

## Testes e limites

Os harnesses `medical_service_harness.lua`, `medical_client_contract_harness.lua` e `medical_security_contract_harness.lua` cobrem timers, reconnect, apresentação, autorização, distância, reserva/rollback, concorrência, revive, respawn, schemas e defaults seguros. As regressões do core/status/HUD/admin/garagem/casas também devem permanecer verdes.

Ainda dependem de runtime FiveM/OneSync/MySQL: animação e controles reais, coordenadas server-side sob OneSync, round-trip do spawnmanager, troca de modelo/appearance, reconnect e restart reais, persistência sob falha, NUI, buckets, distância, duty real e confirmação visual do ponto Pillbox. Billing e perda de itens continuam deliberadamente desativados.

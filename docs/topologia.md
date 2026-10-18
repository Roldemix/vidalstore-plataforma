# Topología de mensajería

Declarada a mano con amqplib en `src/mensajeria/topologia.ts` de cada proyecto. Los nombres son idénticos
entre proyectos porque es el mismo broker. Las seis colas son quorum y durables, y todo mensaje se publica
con `persistent: true`, `content-type: application/json` y los headers `x-evento-id` (UUID) y `x-emitido-en` (ISO 8601).

## Exchanges

| Exchange | Tipo | Qué caso de uso cubre |
|---|---|---|
| `vidalstore.eventos` | topic | Hechos que ya ocurrieron, con varios interesados (avisos y auditoría). El patrón del binding permite que un evento nuevo llegue a la auditoría sin tocar a los productores. |
| `vidalstore.comandos` | direct | Órdenes a un destinatario concreto: `correo.enviar` va solo a la cola de correos. |
| `vidalstore.dlx` | direct | Dead-letter exchange: recibe lo que las colas de trabajo rechazan y lo entrega a la DLQ cuya routing key es el nombre de la cola de origen. |

## Routing keys

| Routing key | Exchange | Quién la publica | Payload mínimo |
|---|---|---|---|
| `compra.realizada` | eventos | licencias-service, tras crear la licencia y antes del 201 | `{ licenciaId, juegoId, usuarioSub, adquiridaEn }` |
| `licencia.revocada` | eventos | licencias-service, tras marcar la licencia como revocada | `{ licenciaId, juegoId, usuarioSub, revocadaPor, motivo }` |
| `juego.publicado` | eventos | catalogo-service, al crear un juego | `{ juegoId, titulo, editorSub }` |
| `correo.enviar` | comandos | consumidor de avisos (nace de un evento) | `{ para, asunto, cuerpo, origen, eventoId }` |

El BFF no publica nada. El `sub` sale siempre del token: `usuarioSub` en la compra, `revocadaPor` en la
revocación y `editorSub` en el juego. En `licencia.revocada`, `usuarioSub` sale de la fila de licencias.

## Colas de trabajo

| Cola | Exchange | Binding | Consumidor | Qué caso de uso cubre |
|---|---|---|---|---|
| `vidalstore.avisos` | eventos | `licencia.revocada` y `compra.realizada` | avisos | Decide a quién avisar y publica `correo.enviar`. |
| `vidalstore.auditoria` | eventos | `#` | auditoría | Guarda cada evento en `eventos_auditoria`. Recibe también lo que se agregue después. |
| `vidalstore.correos` | comandos | `correo.enviar` | correos | «Envía» el correo (log) y guarda la `Notificacion`. |

Argumentos de cada cola de trabajo: `x-dead-letter-exchange = vidalstore.dlx` y
`x-dead-letter-routing-key = <su propio nombre>`.

## Colas de mensajes muertos

| DLQ | Exchange | Binding (routing key) | Consumidor |
|---|---|---|---|
| `vidalstore.avisos.dlq` | dlx | `vidalstore.avisos` | mensajes muertos |
| `vidalstore.auditoria.dlq` | dlx | `vidalstore.auditoria` | mensajes muertos |
| `vidalstore.correos.dlq` | dlx | `vidalstore.correos` | mensajes muertos |

Las DLQ se declaran antes que las colas de trabajo. Si una DLQ no existe cuando llega el primer rechazo,
el mensaje se pierde en silencio.

## Recorrido de un mensaje

- **Normal:** productor → exchange → cola → consumidor → trabajo hecho → `ack`.
- **Mal formado** (no es JSON o falta un campo obligatorio): `nack(false, false)` → DLX → DLQ → fila en `mensajes_muertos`.
- **Fallo transitorio** (Postgres no responde): 3 reintentos con 2 s de espera y luego `nack(false, false)`.
- **DLQ:** el consumidor registra en el log cola de origen, routing key, motivo e intentos (del header `x-death`), inserta en `mensajes_muertos` y hace `ack`. Si Postgres falla, `nack(false, true)`.

Consumidores: `noAck: false` y prefetch 1.
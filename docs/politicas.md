# Políticas de retención y limpieza

Las seis colas son quorum y durables. Sus límites no están puestos a mano en la interfaz:
se declaran en `rabbitmq/politicas.json` y se importan con

    docker exec vidalstore-rabbit1 rabbitmqctl import_definitions /etc/rabbitmq/politicas.json

Las definiciones son del clúster completo: se importan una vez, en cualquiera de los dos nodos.
Sobreviven a `docker compose down` (sin `-v`). Desde un clon limpio hay que importarlas de nuevo.

## Colas de trabajo: `vidalstore.avisos`, `vidalstore.auditoria`, `vidalstore.correos`

Política `vidalstore-colas-trabajo`, patrón `^vidalstore\.(avisos|auditoria|correos)$`.

| Parámetro | Valor | Justificación |
|---|---|---|
| `max-length` | 10000 | Techo de la cola. Los consumidores procesan un mensaje en milisegundos; 10 000 pendientes significa que llevan un buen rato caídos o atascados, y es preferible enterarse a que la cola crezca sin límite. |
| `overflow` | `reject-publish` | Al llegar al techo el broker rechaza (nack) la publicación en vez de borrar mensajes viejos. Quien se entera es el productor, que no recibe la confirmación; licencias-service lo registra como evento no publicado (comportamiento esperado según el código, no probado en vivo con una cola de trabajo llena). Con `drop-head` se perderían avisos en silencio, que es lo que Arturo pidió evitar. |
| `message-ttl` | 86 400 000 ms (24 h) | Un aviso de hace tres días ya no sirve. Al expirar, el mensaje va a la DLQ de su cola (motivo `expired` en `x-death`), así que no se pierde en silencio. **Pendiente de probar en vivo.** |

## Colas de mensajes muertos: `*.dlq`

Política `vidalstore-dlq`, patrón `^vidalstore\.(avisos|auditoria|correos)\.dlq$`.

| Parámetro | Valor | Justificación |
|---|---|---|
| `max-length` | 100000 | Diez veces el techo de una cola de trabajo. La DLQ es la evidencia de los errores, así que tolera mucho más que la cola que la alimenta. Además se vacía sola: su consumidor guarda cada mensaje en `mensajes_muertos` y hace ack. |
| `overflow` | `reject-publish` | Con `drop-head` se borraría primero lo más antiguo, justo la evidencia más vieja. |
| `message-ttl` | (ninguno) | Un mensaje muerto se quiere conservar hasta que alguien lo mire. |
| `delivery-limit` | -1 | El consumidor de mensajes muertos devuelve el mensaje con `nack(false, true)` si Postgres no responde. Sin límite, ese mensaje no se descarta aunque Postgres tarde en volver. |

## Qué pasa con una política mal calibrada en la DLQ

- **TTL en la DLQ:** borra los mensajes muertos por expiración, o sea la evidencia de lo que falló.
- **`drop-head`:** descarta en silencio los más antiguos al llenarse.
- **Techo demasiado bajo:** una DLQ llena rechaza lo que le llega y el mensaje muerto se pierde. Por eso es 10 veces el de las colas de trabajo.

## Qué no cubren estas políticas

- Las colas creadas con `vidalstore-admin` solo quedan cubiertas si su nombre calza con alguno de los patrones.
- `reject-publish-dlx` no se usa: no lo admiten las colas quorum.
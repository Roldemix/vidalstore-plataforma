# Políticas de retención y limpieza

Declaradas en `rabbitmq/politicas.json` e importadas con
`rabbitmqctl import_definitions` (no se configuran a mano en la interfaz).

| Política | Colas de trabajo | DLQ | Por qué |
|---|---|---|---|
| max-length | 10 000 | 100 000 | Techo para que ninguna cola crezca sin límite. La DLQ lo tiene más alto porque guarda la evidencia de los errores. |
| overflow | reject-publish | reject-publish | Al llegar al techo el productor se entera (con confirmaciones) en vez de perder mensajes en silencio. drop-head borraría el mensaje más antiguo sin avisar. reject-publish-dlx no existe en colas quorum. |
| message-ttl | 24 h | sin TTL | Un aviso de hace tres días ya no sirve. Un mensaje muerto sí se quiere conservar. |
| delivery-limit | 20 (por defecto) | sin límite (-1) | El consumidor de mensajes muertos devuelve el mensaje a su DLQ si Postgres falla. Con el límite por defecto, una caída larga de Postgres haría que la DLQ soltara la última copia. |

## Qué pasa en cada caso
- Techo alcanzado en una cola de trabajo: el broker rechaza la publicación y el productor lo sabe.
- Mensaje expirado en una cola de trabajo: al tener DLX, pasa a la DLQ con motivo `expired` (a verificar en la prueba).
- Techo alcanzado en una DLQ: se rechaza lo nuevo; por eso el techo es alto y la DLQ se vacía hacia Postgres.

## A qué cola no le pondría un TTL corto
A las DLQ: una política mal calibrada ahí borra la evidencia de los errores.
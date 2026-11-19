# Consumer groups

## Grupos y responsabilidades

| Grupo | Topics | Tablas de escritura |
|---|---|---|
| `vidalstore-panel` | `vidalstore.actividad`, `vidalstore.compras` | `eventos.kpi_minuto` |
| `vidalstore-alertas` | `vidalstore.actividad` | `eventos.alertas` |
| `vidalstore-historial` | `vidalstore.compras` | `eventos.ventas_semana` |
| `vidalstore.catalogo` | `vidalstore.catalogo` | `eventos.catalogo_estado` |

Cada grupo mantiene offsets independientes. Dentro de un grupo Kafka reparte las
tres particiones entre sus instancias; una cuarta instancia queda sin partición
mientras existan solo tres.

## Orden de procesamiento

Todo mensaje pasa por el mismo camino (`src/streaming/procesar-mensaje.ts`):

1. Se valida el contrato completo (sobre `eventoId`, `tipo`, `version`,
   `emitidoEn` más campos del evento). Los errores quedan tipados:
   `json-invalido`, `falta-<campo>`, `dto-invalido`, `version-desconocida`.
2. Un mensaje inválido **no se reintenta**: se publica en `<topic>.dlt` con los
   headers originales más `x-motivo` y `x-grupo`, y el offset se confirma.
3. Si el grupo ya procesó ese `eventoId` (`eventos.eventos_procesados` con
   `UNIQUE(grupo, evento_id)`), se confirma sin volver a escribir.
4. Solo las fallas transitorias de PostgreSQL se reintentan: 3 reintentos con
   espera de 1 s, 2 s y 4 s. Si sigue caído, el mensaje va al `.dlt` con
   `x-motivo=postgres-noresponde`.
5. Cualquier otro error de negocio va al `.dlt` con `x-motivo=error-procesamiento`;
   un duplicado de una restricción `UNIQUE` se trata como "ya procesado".

`vidalstore.catalogo` no tiene `.dlt`: sus mensajes inválidos solo se registran
en el log y se confirman, porque el catálogo se reconstruye desde el topic
compactado.

## Revisar offsets

```bash
export MSYS_NO_PATHCONV=1
docker compose exec broker-1 /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server broker-1:19092 --all-groups --describe
```

El administrador de la EP3 expone el mismo estado con lag por partición:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  localhost:3020/v1/admin/kafka/grupos
```

## Rebobinar

Solo un grupo detenido se puede rebobinar (si corre, el API responde 409). Hay
dos formas equivalentes:

```bash
# CLI, en local
docker compose exec broker-1 /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server broker-1:19092 --group vidalstore-historial \
  --topic vidalstore.compras --reset-offsets --to-earliest --execute
```

```bash
# API de la EP3 (grupo detenido)
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"alPrincipio":true}' \
  localhost:3020/v1/admin/kafka/grupos/vidalstore-historial/offsets
```

Después de un rebobinado hay que borrar las filas de ese grupo en
`eventos.eventos_procesados` y, si se reprocesa `vidalstore.compras`
completo, las filas de `eventos.ventas_semana` o `eventos.kpi_minuto` con los
`evento_id` que se van a releer. Si no, la idempotencia por grupo descarta el
reproceso. La EP3 no borra datos de negocio automáticamente.

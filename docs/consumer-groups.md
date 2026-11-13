# Consumer groups

## Grupos y responsabilidades

| Grupo | Topics | Tablas de lectura |
|---|---|---|
| `vidalstore-panel` | `vidalstore.actividad`, `vidalstore.compras` | `eventos.kpi_minuto` |
| `vidalstore-alertas` | `vidalstore.actividad` | `eventos.alertas` |
| `vidalstore-historial` | `vidalstore.compras` | `eventos.ventas_semana` |

Cada grupo mantiene offsets independientes. Por eso panel y alertas pueden
leer `vidalstore.actividad` sin estorbarse. Dentro de un grupo Kafka reparte
las tres particiones entre sus instancias; una cuarta instancia queda sin
partición asignada mientras existan solo tres.

Los consumidores usan `autocommit: false` y confirman el offset después de la
validación y la escritura en PostgreSQL. Las tablas tienen `UNIQUE(evento_id)`
(o `UNIQUE(grupo, evento_id)`), por lo que una reentrega después de una caída
entre `INSERT` y `commit` no suma dos veces.

Para comprobar offsets y reparto en local:

```bash
export MSYS_NO_PATHCONV=1
docker compose exec broker-1 /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server broker-1:19092 --all-groups --describe
```

Para reprocesar el historial, el grupo debe estar detenido:

```bash
docker compose exec broker-1 /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server broker-1:19092 --group vidalstore-historial \
  --topic vidalstore.compras --reset-offsets --to-earliest --execute
```

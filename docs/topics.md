# Topics Kafka

Todos los topics tienen tres particiones, factor de replicación 3,
`min.insync.replicas=2` y los productores usan `acks=all`. Así se mantiene
disponibilidad sin aceptar escrituras cuando solo queda un réplica sana.

| Topic | Key | Política | Retención | Motivo |
|---|---|---|---:|---|
| `vidalstore.actividad` | `juegoId` | delete | 7 días | Ordena la actividad de cada juego y limita el almacenamiento de eventos operacionales. |
| `vidalstore.compras` | `usuarioSub` | delete | 7 días | Mantiene compra y revocación del jugador en orden; puede concentrar carga de un jugador activo en una partición. |
| `vidalstore.catalogo` | `juegoId` | compact | 30 días | Permite reconstruir el último estado de cada juego desde el offset 0. |
| `vidalstore.actividad.dlt` | original | delete | 30 días | Conserva eventos de actividad rechazados para diagnóstico y reproceso. |
| `vidalstore.compras.dlt` | original | delete | 30 días | Conserva compras o revocaciones que no pudieron procesarse. |

El script reproducible es [`../../kafka/topics.sh`](../../kafka/topics.sh).
La compactación del catálogo evita acumular estados obsoletos, pero conserva
la última publicación por `juegoId`.

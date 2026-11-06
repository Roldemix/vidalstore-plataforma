# Vidalstore Plataforma

## Levantar el entorno local

Desde la raíz del proyecto, en Git Bash:

```bash
bash levantar.sh
```

El comando crea los archivos `.env` que todavía no existan, espera a RabbitMQ,
PostgreSQL y Kafka, crea los topics con sus particiones, réplicas y políticas, y
deja disponibles las interfaces:

- Kafka UI: <http://localhost:8085>
- RabbitMQ Management: <http://localhost:15672>
- Gateway: <http://localhost:8080>
- Frontend: <http://localhost:4200>

Los servicios que se ejecutan dentro de Compose usan:

```text
broker-1:19092,broker-2:19092,broker-3:19092
```

Un proceso ejecutado directamente en el equipo debe usar:

```text
localhost:9092,localhost:9094,localhost:9096
```

Para comprobar la distribución y el ISR de un topic:

```bash
export MSYS_NO_PATHCONV=1
docker compose exec broker-1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server broker-1:19092 \
  --describe --topic vidalstore.compras
```

No se deben guardar credenciales reales en el repositorio. Los archivos `.env`
locales están excluidos por la configuración de la plataforma.

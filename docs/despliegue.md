# Despliegue EP3

El sistema corre en dos nubes y se despliega solo cuando se integra a `main` un
cambio en [`deploy/versiones.env`](../deploy/versiones.env). No hay scripts que
desplieguen la aplicación: los comandos de despliegue viven en
[`.github/workflows/desplegar.yml`](../.github/workflows/desplegar.yml). Los
scripts de `deploy/` solo preparan la infraestructura y los permisos.

## Arquitectura desplegada

| Nube | Máquina | IP privada | Servicios | Entrada |
|---|---|---|---|---|
| AWS | `gw-aws` | `10.0.1.10` | Caddy con TLS interno | 443 solo desde la VNet de Azure |
| AWS | `servicios` | `10.0.11.10` | gateway, catálogo, licencias, eventos | 8080 dentro del SG; 3001/3002/3010 desde Azure |
| AWS | `gestion` | `10.0.11.20` | admin, Kafka UI | `127.0.0.1`, solo túnel SSM |
| AWS | `mq-1`, `mq-2`, `mq-3` | `10.0.21.10`, `10.0.22.10`, `10.0.21.11` | Kafka y RabbitMQ | solo dentro del SG |
| AWS | `datos` | `10.0.21.20` | PostgreSQL | solo dentro del SG |
| Azure | `gw-azure` | `10.1.1.10` | Caddy público + frontend estático | 80 y 443 desde Internet |
| Azure | `bff` | `10.1.2.10` | BFF | 8081 desde `gw-aws` y `gw-azure` |

El único nombre público es la IP de `gw-azure` con guiones y el sufijo
`sslip.io`, por ejemplo `20-55-1-10.sslip.io`. Let's Encrypt valida por HTTP-01
en el puerto 80 y el sitio queda en 443. No hace falta comprar un dominio ni
editar DNS.

### Camino de una petición

```text
navegador ──HTTPS──► gw-azure ──HTTPS interno──► gw-aws ──HTTP──► gateway (AWS)
                        │                                            │
                        │ frontend estático                          ▼
                        └──────────────────────────────────────► BFF (Azure)
                                                                     │
                                          ┌──────────────────────────┘
                                          ▼
                     catálogo / licencias / eventos (AWS, ruta privada)
```

- `gw-azure` sirve `/` desde el contenedor `frontend` y reenvía `/v1/*` a
  `gw-aws`, validando su CA interna con `/opt/vidalstore/certs/aws-ca.crt`.
- `gw-aws` entrega `/v1/*` tal cual al gateway, que expone sus rutas bajo
  `/v1` y valida el JWT antes de reenviar al BFF de Azure.
- El gateway valida el JWT y reenvía al BFF de Azure.
- El BFF autoriza por `cognito:groups` y compone las respuestas llamando a los
  servicios de AWS por la ruta privada (`http://10.0.11.10:3001`, `:3002`,
  `:3010`). Los servicios vuelven a validar el JWT que el BFF les pasa.
- `admin` y Kafka UI no se publican en el borde: solo por túnel de Session
  Manager a `gestion`. Así se cumple que las herramientas de administración no
  quedan en Internet.

## Imágenes

Cada repositorio tiene `imagen.yml` con dos trabajos:

1. `pruebas`: `npm ci`, compilación y pruebas unitarias desde un clon limpio.
2. `imagen`: publica en GHCR **solo** si `pruebas` terminó bien y la rama es
   `main`. El tag es el SHA del commit.

```bash
docker pull ghcr.io/roldemix/vidalstore-eventos:<sha>
```

## Despliegue continuo

1. El repositorio del servicio se integra a `main`; `imagen.yml` publica el SHA.
2. En `vidalstore-plataforma` se cambia esa línea de `deploy/versiones.env` al
   SHA nuevo.
3. Al integrar ese cambio a `main`, `desplegar.yml` corre dos trabajos, uno en
   cada nube, con un runner autoalojado por nube:
   - `aws` (etiqueta `aws`, instalado en `servicios`): `docker compose pull` y
     `up -d` de `deploy/aws/servicios/compose.yml`; por Session Manager copia
     `deploy/aws/gestion/compose.yml` a `gestion` y ejecuta el mismo
     `pull` + `up -d`, esperando el resultado del comando; y hace lo propio con
     el `compose.yml` y el `Caddyfile` de `gw-aws`.
   - `azure` (etiqueta `azure`, instalado en `gw-azure`): actualiza el borde y
     el frontend, y por SSH copia el compose a `bff` y lo actualiza.

Los archivos `compose.yml` y `Caddyfile` viajan en el checkout del runner: las
máquinas solo guardan su `.env` (y la CA interna en `gw-azure`). No hay
credenciales de AWS ni de Azure en GitHub.

### Instalar el runner de AWS

En `servicios`, por Session Manager:

```bash
sudo mkdir -p /opt/actions-runner && cd /opt/actions-runner
curl -o runner.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-linux-x64-2.338.2.tar.gz
sudo tar xzf runner.tar.gz
sudo dnf install -y libicu || true   # dependencia de .NET en AL2023
sudo ./config.sh --url https://github.com/Roldemix/vidalstore-plataforma \
  --token <TOKEN_DE_UN_USO> --labels aws --unattended --replace
sudo ./svc.sh install && sudo ./svc.sh start
```

El token se obtiene en *Settings → Actions → Runners → New self-hosted runner*
y no se guarda en el repositorio. El runner usa el perfil de instancia
(`LabInstanceProfile`) para llamar a SSM, así que no hay credenciales AWS en
GitHub. La cuenta `ec2-user` tiene que estar en el grupo `docker` y
`desplegar-ec2.sh` ya deja instalados `aws` (CLI v2) y el plugin
`docker compose`.

### Instalar el runner de Azure

En `gw-azure`, con `az vm run-command invoke`:

```bash
sudo mkdir -p /opt/actions-runner && cd /opt/actions-runner
curl -o runner.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-linux-x64-2.338.2.tar.gz
sudo tar xzf runner.tar.gz
sudo ./bin/installdependencies.sh
sudo chown -R azureuser:azureuser /opt/actions-runner
sudo -u azureuser env HOME=/home/azureuser ./config.sh \
  --url https://github.com/Roldemix/vidalstore-plataforma \
  --token <TOKEN_DE_UN_USO> --labels azure --unattended --replace
sudo ./svc.sh install azureuser && sudo ./svc.sh start
```

El runner queda como `azureuser` (en el grupo `docker`). Para que pueda leer
la llave del BFF y escribir el compose del borde:

```bash
sudo chown -R azureuser:azureuser /opt/vidalstore/gw-azure /opt/vidalstore/llaves
```

No hay secretos en GitHub: las imágenes de GHCR son públicas y las credenciales
de AWS y Azure nunca salen de sus máquinas. El runner de AWS usa el perfil de
instancia y el de Azure solo la llave local hacia `bff`.

## Preparar AWS

1. Red e instancias: [`deploy/aws/crear-infraestructura.sh`](../deploy/aws/crear-infraestructura.sh)
   y [`deploy/aws/desplegar-ec2.sh`](../deploy/aws/desplegar-ec2.sh).
2. Reglas del Security Group de la EP3:

   ```bash
   export VPC_ID=vpc-...
   bash deploy/aws/permisos-e3.sh
   ```

   Deja 443 y 3001/3002/3010 solo para `10.1.0.0/16` (la VNet de Azure), sin
   nada abierto a Internet y sin 22. El script avisa si falta la ruta de vuelta
   hacia Azure (peering o VPN de la EP2).
3. Crear los topics antes de levantar la aplicación. El script
   [`kafka/topics.sh`](../../kafka/topics.sh) es para el compose local; en la
   nube se ejecuta el mismo CLI sobre el broker (por Session Manager en `mq-1`;
   si Kafka corre en un contenedor, se antepone `docker exec <contenedor>`):

   ```bash
   K=/opt/kafka/bin/kafka-topics.sh
   B=10.0.21.10:9092
   for topico in compras actividad; do
     $K --bootstrap-server $B --create --if-not-exists --topic vidalstore.$topico \
       --partitions 3 --replication-factor 3 --config min.insync.replicas=2 \
       --config retention.ms=604800000
     $K --bootstrap-server $B --create --if-not-exists --topic vidalstore.$topico.dlt \
       --partitions 3 --replication-factor 3 --config min.insync.replicas=2 \
       --config retention.ms=2592000000
   done
   $K --bootstrap-server $B --create --if-not-exists --topic vidalstore.catalogo \
     --partitions 3 --replication-factor 3 --config min.insync.replicas=2 \
     --config cleanup.policy=compact --config retention.ms=2592000000
   ```

   También se pueden crear desde la API de la EP3 con el túnel abierto
   (`POST /v1/admin/kafka/topics`).

4. En cada máquina, solo el `.env` (los ejemplos están en
   `deploy/aws/*/.env.ejemplo`, nunca se versionan claves reales):

   ```bash
   sudo mkdir -p /opt/vidalstore/{servicios,gestion}
   sudo cp deploy/aws/servicios/.env.ejemplo /opt/vidalstore/servicios/.env
   sudo cp deploy/aws/gestion/.env.ejemplo /opt/vidalstore/gestion/.env
   ```

5. `gw-aws` no abre SSH: el flujo le escribe `compose.yml` y `Caddyfile` por
   SSM en cada despliegue. El certificado interno se genera la primera vez y
   su CA hay que copiarla a `gw-azure` una sola vez (si se borra el volumen,
   se repite). En una sesión de Session Manager sobre `gw-aws`:

   ```bash
   sudo docker cp vidalstore-gw-aws-borde-1:/data/caddy/pki/authorities/local/root.crt \
     /tmp/aws-ca.crt
   sudo base64 -w0 /tmp/aws-ca.crt
   ```

   Ese valor se escribe en `gw-azure` (por `az vm run-command`):

   ```bash
   az vm run-command invoke -g rg-vidalstore-e3 -n gw-azure \
     --command-id RunShellScript \
     --scripts "mkdir -p /opt/vidalstore/certs && echo '<BASE64>' | base64 -d > /opt/vidalstore/certs/aws-ca.crt"
   ```

   Sin ese archivo el borde público responde 502 al llamar a `/v1/*`.

## Preparar Azure

```bash
bash deploy/azure/red.sh
bash deploy/azure/maquinas.sh
```

`maquinas.sh` imprime el paso para generar la llave en `gw-azure` y autorizarla
en `bff`. Después, en cada máquina solo el `.env`:

```bash
# gw-azure
sudo mkdir -p /opt/vidalstore/gw-azure /opt/vidalstore/certs
sudo cp deploy/azure/gw-azure/.env.ejemplo /opt/vidalstore/gw-azure/.env   # editar DOMINIO
sudo cp <aws-ca.crt> /opt/vidalstore/certs/aws-ca.crt

# bff
sudo mkdir -p /opt/vidalstore/bff
sudo cp deploy/azure/bff/.env.ejemplo /opt/vidalstore/bff/.env
```

Para ahorrar crédito: `bash deploy/azure/apagar.sh` y, al volver,
`bash deploy/azure/encender.sh` (la IP pública es estática).

## Verificación de la entrega

### HTTPS y mismo origen

```bash
curl -I https://<ip-de-gw-azure>.sslip.io
# Sin token, el gateway responde 401: la ruta llego hasta AWS.
curl -s -o /dev/null -w '%{http_code}\n' https://<ip-de-gw-azure>.sslip.io/v1/catalogo
# Con el token de un usuario, devuelve el catalogo.
curl -s -H "Authorization: Bearer $TOKEN" \
  https://<ip-de-gw-azure>.sslip.io/v1/catalogo | head
```

El frontend no tiene URLs fijas: fuera de `localhost` usa `${origin}/v1`
(`src/app/catalogo.ts`), y el interceptor solo adjunta el token al gateway local
o a esa misma ruta.

### Mensajes desviados

En `mq-3`, por Session Manager:

```bash
K=/opt/kafka/bin
$K/kafka-get-offsets.sh --bootstrap-server 10.0.21.11:9092 \
  --topic vidalstore.actividad.dlt
$K/kafka-get-offsets.sh --bootstrap-server 10.0.21.11:9092 \
  --topic vidalstore.compras.dlt
```

Con el dataset de referencia se esperan **58** mensajes en
`vidalstore.actividad.dlt` (29 mensajes inválidos × los grupos `vidalstore-panel`
y `vidalstore-alertas`) y **8** en `vidalstore.compras.dlt` (4 inválidos ×
`vidalstore-panel` y `vidalstore-historial`). Si algún mensaje válido falla al
procesarse, se sumará con `x-motivo=error-procesamiento`. Cada desviado lleva
los headers originales más `x-motivo` (`json-invalido`, `falta-<campo>`,
`dto-invalido`, `version-desconocida`, `postgres-noresponde`) y `x-grupo`.

Los grupos son `vidalstore-panel`, `vidalstore-alertas`,
`vidalstore-historial` y `vidalstore.catalogo`. El detalle está en
[consumer-groups.md](consumer-groups.md).

### Administración

Solo por túnel, nunca por Internet:

```bash
aws ssm start-session --target <id-de-gestion> \
  --document-name AWS-StartPortForwardingSession \
  --parameters 'portNumber=3020,localPortNumber=3020'
```

Con el token de un administrador de Cognito, las rutas de la EP3 quedan en
`http://localhost:3020/v1/admin/kafka`:

```bash
TOKEN=<access_token>
curl -s -H "Authorization: Bearer $TOKEN" localhost:3020/v1/admin/kafka/topics
curl -s -H "Authorization: Bearer $TOKEN" localhost:3020/v1/admin/kafka/grupos
```

Kafka UI sigue el mismo camino, con `portNumber=8085`.

## Pendiente de completar antes de entregar

Lo que no se puede resolver desde el código:

- [ ] Reemplazar los ceros de `deploy/versiones.env` por los SHA reales de cada
      repositorio después de la primera ejecución de `imagen.yml`.
- [ ] Anotar las IP públicas reales (la de `gw-azure` y la de salida de
      `gw-aws`) y el `sslip.io` usado en `DOMINIO`.
- [ ] Registrar los dos runners autoalojados (`aws` y `azure`).
- [ ] Copiar `aws-ca.crt` a `gw-azure` y comprobar `curl --cacert` contra
      `https://10.0.1.10` desde esa máquina.
- [ ] Verificar la ruta privada entre Azure y AWS (VPN o peering de la EP2). Sin
      ella, `gw-azure` no alcanza `gw-aws`, el BFF no alcanza los servicios y
      `/v1/*` devuelve 502.
- [ ] Reemplazar las capturas de la sección de verificación en el informe.

---
title: "VidalStore EP3: despliegue multicloud"
---

# 1. Resumen

VidalStore se despliega en dos nubes. **AWS (us-east-1, Learner Lab)** aloja los servicios, la mensajería, la base de datos y la administración. **Azure (northcentralus)** aloja el único punto público (`gw-azure`, con el frontend) y el BFF privado. Todo el despliegue se hace con el workflow `.github/workflows/desplegar.yml` y dos *self-hosted runners*; en GitHub no hay secretos.

| Elemento | Valor |
|---|---|
| Repositorio de infraestructura | `roldemix/vidalstore-plataforma` (privado) |
| Imágenes | `ghcr.io/roldemix/vidalstore-*` (7 paquetes públicos) |
| Sitio público | `https://vidalstore-ep3.northcentralus.cloudapp.azure.com` |
| Borde AWS | `https://54-225-233-40.sslip.io` (Elastic IP `54.225.233.40`) |

# 2. Arquitectura

## 2.1 AWS: 8 instancias EC2 (límite del Learner Lab)

| Instancia | Subred / IP privada | Función |
|---|---|---|
| `vidalstore-nat` | pública, 10.0.1.5 | Salida a Internet de las subredes privadas (instancia NAT, sin NAT Gateway) |
| `vidalstore-gw-aws` | pública, 10.0.1.10 | Caddy con certificado automático; 443 solo desde `gw-azure` |
| `vidalstore-servicios` | app, 10.0.11.10 | Gateway y servicios de aplicación |
| `vidalstore-gestion` | app, 10.0.11.20 | `vidalstore-admin`, Kafka UI y runner `aws` |
| `vidalstore-mq-1/2/3` | datos, 10.0.21.10 / 10.0.22.10 / 10.0.21.11 | Kafka y RabbitMQ |
| `vidalstore-datos` | datos, 10.0.21.20 | PostgreSQL |

Todas usan `LabInstanceProfile`, sin SSH ni llaves: se administran con AWS Systems Manager (Session Manager). Se verificó que las 8 aparecen `Online` en SSM.

## 2.2 Azure

| VM | IP | Función |
|---|---|---|
| `gw-azure` | 10.1.1.10 / pública `20.221.220.67` | Borde público: Caddy (TLS), frontend, reenvío y NAT de `bff` |
| `bff` | 10.1.2.10 (sin IP pública) | BFF y runner `azure` |

Red `vnet-vidalstore` (10.1.0.0/16) con las subredes `snet-gw` y `snet-bff`. `bff` sale a Internet y a AWS por `gw-azure` (ruta definida por el usuario con reenvío y `MASQUERADE`). Región `northcentralus` por la política de la suscripción Azure for Students (cuota de 6 vCPU; se usan 4).

# 3. Cumplimiento de las reglas

**Cero secretos en GitHub.** `gh secret list` devuelve vacío. Las imágenes se descargan sin login; se verificó con `docker logout ghcr.io` y `docker pull` para las 7:

```
OK ghcr.io/roldemix/vidalstore-gateway:2b2091aead2ca762480dd5920cb5eeb952066d9e
OK ghcr.io/roldemix/vidalstore-bff:0d0bb228cd1ddb5041b8a8f5cd0e0b780c88021d
OK ghcr.io/roldemix/vidalstore-catalogo-service:4da9b6bbad431664c71311cf755db8c50d07e7c1
OK ghcr.io/roldemix/vidalstore-licencias-service:8e0a7ad446f6423018e23da2d3078283de298b93
OK ghcr.io/roldemix/vidalstore-eventos:100589529d2d2da7f05e62a1f18fef6a755f2ebd
OK ghcr.io/roldemix/vidalstore-admin:bed8182cbe0063c732a268decc5c3e5f56d5a30c
OK ghcr.io/roldemix/vidalstore-frontend:643b9e9a712cb218e07144d998f9cfd36e88acbd
```

**Solo Variables de repositorio**: `BUCKET`, `FRONTEND_URL` y `AWS_URL`.

| Variable | Valor |
|---|---|
| `BUCKET` | `vidalstore-ep3-roldemix-20261120` |
| `FRONTEND_URL` | `https://vidalstore-ep3.northcentralus.cloudapp.azure.com` |
| `AWS_URL` | `https://54-225-233-40.sslip.io` |

**Secretos en las nubes.**

- AWS: `/vidalstore/servicios.env` y `/vidalstore/gestion.env` en Systems Manager Parameter Store (`SecureString`). La instancia los escribe con su rol IAM en cada despliegue (se verificó la lectura desde `gestion`).
- Azure: `/opt/vidalstore/secretos/bff.env` y `/opt/vidalstore/secretos/gw-azure.env` (permisos 600, directorio 700).

**Runners.**

| Runner | Etiqueta | Máquina | Cómo despliega |
|---|---|---|---|
| `aws-gestion` | `aws` | `gestion` (Amazon Linux; `git`, `libicu`, `tar`) | `aws ssm send-command` a `servicios`, `gestion` y `gw-aws`, con su rol IAM |
| `azure-bff` | `azure` | `bff` (Ubuntu, privada) | Local en `bff`; SSH dentro de la VNet a `gw-azure` con una llave generada en `bff` |

**Red y HTTPS.** El Security Group de `gw-aws` abre el 80 (reto ACME) y el 443 solo a `20.221.220.67/32`; no hay 22 abierto en ninguna máquina. `gw-aws` usa Caddy con el dominio `<ip-con-guiones>.sslip.io`. `gw-azure` usa Caddy en `network_mode: host` con `DOMINIO=vidalstore-ep3.northcentralus.cloudapp.azure.com`. No se usa `aws-ca.crt`.

# 4. Flujo de despliegue

`desplegar.yml` se ejecuta con push a `main` que cambie `deploy/**`, o a mano (`workflow_dispatch`). Tiene 4 jobs:

1. **validar** (GitHub-hosted): Variables presentes, sintaxis de los scripts, SHA de 40 caracteres y descarga anónima de las 7 imágenes.
2. **aws** (runner `aws`): escribe el `.env` desde Parameter Store y despliega con `docker compose` en `servicios`, `gestion` y `gw-aws` por SSM.
3. **azure** (runner `azure`): despliega el BFF en local y `gw-azure` por SSH.
4. **humo** (runner `azure`): comprueba el sitio y el borde de AWS; la salida de `bff` pasa por la IP de `gw-azure`, la única que acepta el 443 de `gw-aws`.

Estado del último run: **[completar: URL del run y resultado de los 4 jobs]**.

## 4.1 Certificado real en `gw-aws`

El Caddyfile de `gw-aws` arranca en modo *staging* (`acme_ca` de pruebas). Cuando el certificado de pruebas sale bien, se comenta esa línea, se hace merge y el workflow reinicia Caddy con `--force-recreate`, sin borrar el volumen `/data`.

**[completar: emisor antes (STAGING) y después (Let's Encrypt/ZeroSSL)]**

# 5. Acceso a las herramientas

Kafka UI y `vidalstore-admin` no tienen IP pública: se acceden solo por túnel de Session Manager hacia `gestion`:

```
aws ssm start-session --target <id-gestion> \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=3020,localPortNumber=3020
```

Luego `http://localhost:3020`. **[completar: puerto de Kafka UI]**

# 6. Pruebas obligatorias de Kafka (evidencias)

| N.º | Prueba | Estado |
|---|---|---|
| 1 | Mensaje a la cola `.dlt` con el simulador | Pendiente |
| 2 | Caída de PostgreSQL con 3 reintentos | Pendiente |
| 3 | Rutas de `vidalstore-admin` | Pendiente |
| 4 | Rebobinado de 4 pasos de `vidalstore-historial` | Pendiente |
| 5 | Salida adicional exigida por la rúbrica | Pendiente |

Para cada prueba se pegará aquí el comando ejecutado y su salida real.

**[completar evidencia 1]**

**[completar evidencia 2]**

**[completar evidencia 3]**

**[completar evidencia 4]**

**[completar evidencia 5]**

# 7. Problemas encontrados y solución

- **Docker en `gw-azure` descartaba el tráfico de `bff`.** Docker pone `FORWARD` en `DROP`; `bff` no tenía salida a Internet. Se añadieron reglas en `DOCKER-USER` para `10.1.0.0/16` con un servicio de systemd que corre tras Docker.
- **Instancias de una versión anterior del script.** Se terminaron y se recrearon con el script nuevo (instancia NAT, `datos`, 8 en total).
- **Runner antiguo en `gw-azure`.** Se retiró para que los jobs de Azure corran en `bff`.
- **Git Bash convertía `/vidalstore/...` en rutas de Windows.** Se fijó `MSYS_NO_PATHCONV=1`.
- **Región de Azure.** `FRONTEND_URL` se corrigió de `eastus2` a `northcentralus`.

# 8. Estructura del repositorio

```
.github/workflows/desplegar.yml
deploy/versiones.env
deploy/aws/    desplegar-ec2.sh  permisos-e3.sh  ssm-secretos.sh  runner-gestion.sh
               servicios/  gestion/  gw-aws/
deploy/azure/  red.sh  maquinas.sh  secretos.sh  runner-bff.sh
               bff/  gw-azure/
```

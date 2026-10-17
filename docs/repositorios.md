# Mapa de repositorios

| Repositorio | Enlace | Pieza | Carpeta |
|---|---|---|---|
| vidalstore-frontend | https://github.com/Roldemix/vidalstore-frontend | frontend (Angular) | raíz |
| vidalstore-backend | https://github.com/Roldemix/vidalstore-backend | gateway, BFF, catálogo y licencias | `gateway/`, `bff/`, `catalogo-service/`, `licencias-service/` |
| vidalstore-plataforma | https://github.com/Roldemix/vidalstore-plataforma | plataforma (compose, políticas, docs) | raíz |
| vidalstore-eventos | https://github.com/Roldemix/vidalstore-eventos | eventos (consumidores y persistencia) | raíz |
| vidalstore-admin | https://github.com/Roldemix/vidalstore-admin | admin del broker | raíz |

Notas:
- `catalogo-service/` es el catálogo (puerto 3001) y `licencias-service/` es el servicio de licencias (puerto 3002). Este último es el que en la EP1 se llamó «biblioteca» y no se renombra.
- El BFF vive como carpeta en `vidalstore-backend` (`bff/`, puerto 8081).

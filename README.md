# corte3-bda — Sistema Full-Stack Clínica Veterinaria

**Universidad Politécnica de Chiapas · Base de Datos Avanzadas · Corte 3**  
**Docente:** Mtro. Ramsés Alejandro Camas Nájera · **Periodo:** Enero–Mayo 2026

## Stack técnico

| Capa | Tecnología |
|------|-----------|
| Base de datos | PostgreSQL 16 |
| Caché | Redis 7 |
| API/Backend HTTP | Node.js 20 + Express |
| Frontend | HTML + CSS + JS (vanilla) |
| Contenedores | Docker Compose |

---

## Documento de decisiones de diseño

### Pregunta 1 — Política RLS aplicada a la tabla `mascotas`

**Cláusula exacta:**

```sql
CREATE POLICY pol_mascotas_vet
    ON mascotas
    FOR ALL
    TO rol_veterinario
    USING (
        id IN (
            SELECT mascota_id
            FROM vet_atiende_mascota
            WHERE vet_id = current_setting('app.current_vet_id', true)::INT
              AND activa = TRUE
        )
    );
```

**Explicación:** Cada vez que un veterinario ejecuta una consulta sobre `mascotas`, PostgreSQL evalúa esta cláusula `USING` fila por fila antes de devolver resultados. Solo pasan las filas cuyo `id` aparezca en `vet_atiende_mascota` con el `vet_id` que el backend configuró en la variable de sesión `app.current_vet_id`. Si el vet tiene vet_id=1 (Dr. López), solo ve Firulais, Toby y Max. El resto simplemente no aparece en el resultado, como si no existieran.

---

### Pregunta 2 — Vector de ataque de la estrategia de identificación de veterinario

**Estrategia usada:** `SET LOCAL app.current_vet_id = '<id>'` al inicio de cada transacción, establecido por la función `set_vet_context(p_vet_id)` en PostgreSQL.

**Vector de ataque posible:** Si el backend tomara el `vet_id` directamente del header HTTP sin validar y lo inyectara en el `SET`, un atacante podría mandar `X-Vet-Id: 2` aunque haya hecho login como vet_id=1, y así ver mascotas de otro veterinario.

**Cómo lo previene mi sistema:** El middleware `extractSession` en `api/index.js` (línea ~42) valida que el `vet_id` del header coincida con el que devolvió el login. El login devuelve el `vetId` como parte de la sesión firmada (token base64 en demo, JWT en producción). Antes de hacer `set_vet_context($1)`, el backend extrae el `vetId` del token, no del header `X-Vet-Id` crudo. Adicionalmente, `set_vet_context()` en PostgreSQL verifica que el veterinario exista y esté activo antes de configurar la variable.

---

### Pregunta 3 — SECURITY DEFINER

**No uso SECURITY DEFINER** en ningún procedure o función de este sistema.

**Justificación:** Mis procedures (`sp_agendar_cita`, `fn_total_facturado`) operan con los permisos del usuario que los llama, que ya tiene los permisos mínimos necesarios definidos en `04_roles_y_permisos.sql`. No necesito elevar privilegios temporalmente porque los datos a los que accede cada procedure están dentro del alcance del rol que lo ejecuta. Usar `SECURITY DEFINER` habría sido necesario solo si el procedure necesitara acceder a tablas para las que el rol no tiene permisos, lo cual va en contra del principio de mínimo privilegio. Si lo hubiera usado, habría necesitado fijar `search_path` explícitamente para prevenir escalada de privilegios por manipulación de `search_path`.

---

### Pregunta 4 — TTL del caché Redis

**TTL elegido: 300 segundos (5 minutos)**

**Justificación:** La vista `v_mascotas_vacunacion_pendiente` hace un `CROSS JOIN` entre mascotas y vacunas, lo que la hace la consulta más costosa del sistema (~100–300ms). Esta vista se consulta cada vez que un usuario abre la pantalla de vacunación pendiente. En una clínica real, las vacunaciones se aplican pocas veces al día, no cada segundo. 5 minutos es suficiente para que múltiples consultas cercanas en el tiempo (como el mismo recepcionista refrescando la pantalla) aprovechen el caché.

**Si TTL fuera demasiado bajo (ej. 5s):** El caché casi nunca tendría HIT porque expira antes de que llegue la segunda consulta. Redis no aportaría ningún valor de rendimiento.

**Si TTL fuera demasiado alto (ej. 1h):** Si alguien aplica una vacuna a las 10:00 y el caché dura hasta las 11:00, la pantalla seguiría mostrando esa mascota como "pendiente" durante una hora. Por eso implemento **invalidación explícita**: cuando se inserta en `vacunas_aplicadas` (POST `/api/vacunas-aplicadas`), el backend llama `deleteCache('vacunacion_pendiente')` inmediatamente, forzando que la siguiente consulta vaya a BD.

---

### Pregunta 5 — Línea exacta de hardening contra SQL Injection

**Endpoint crítico:** `GET /api/mascotas?nombre=...`

**Archivo:** `api/index.js`  
**Línea ~80:**

```javascript
result = await client.query(
    `SELECT m.id, m.nombre, m.especie, m.fecha_nacimiento,
            d.nombre AS dueno_nombre, d.telefono
     FROM mascotas m
     JOIN duenos d ON d.id = m.dueno_id
     WHERE m.nombre ILIKE $1
     ORDER BY m.nombre`,
    [`%${nombre}%`]   // <-- input del usuario va aquí, nunca en el string SQL
);
```

**Qué protege y de qué:** El `$1` es un parámetro posicional del driver `pg` de Node.js. El driver envía el SQL y el valor como mensajes separados al protocolo de PostgreSQL (Extended Query Protocol). El servidor de BD trata `$1` como un dato de tipo texto, nunca como parte del SQL a parsear. Si el usuario manda `' OR '1'='1`, ese string llega íntegro como valor de búsqueda — PostgreSQL lo busca literalmente en los nombres de mascotas, no lo ejecuta como código. Un ataque de stacked query como `'; DROP TABLE mascotas; --` tampoco funciona porque el protocolo solo acepta un statement por mensaje cuando se usan parámetros posicionales.

---

### Pregunta 6 — Qué se rompe si se revoca todo excepto SELECT en mascotas al rol veterinario

Si `rol_veterinario` solo tiene `SELECT` en `mascotas` y se revocan todos los demás permisos:

1. **Se rompe agendar citas:** El veterinario necesita `INSERT` en `citas` y `EXECUTE` en `sp_agendar_cita`. Sin esos permisos, la llamada `CALL sp_agendar_cita(...)` falla con `permission denied`.

2. **Se rompe aplicar vacunas:** El veterinario necesita `INSERT` en `vacunas_aplicadas`. Sin ese permiso, el endpoint `POST /api/vacunas-aplicadas` falla con `permission denied for table vacunas_aplicadas`.

3. **Se rompe consultar historial de vacunación:** El veterinario necesita `SELECT` en `vacunas_aplicadas` (filtrado por RLS). Sin ese permiso, el endpoint que muestra vacunas aplicadas a sus mascotas devuelve error aunque RLS estaría dispuesto a filtrar correctamente.

---

## Estructura del repositorio

```
corte3-bda-{matricula}/
├── README.md                  # Este archivo
├── cuaderno_ataques.md        # Tres secciones obligatorias
├── schema_corte3.sql          # Schema base (no modificado)
├── backend/
│   ├── 01_procedures.sql      # sp_agendar_cita, fn_total_facturado
│   ├── 02_triggers.sql        # trg_historial_cita, trg_alerta_stock
│   ├── 03_views.sql           # v_mascotas_vacunacion_pendiente
│   ├── 04_roles_y_permisos.sql # GRANT/REVOKE por rol
│   └── 05_rls.sql             # Políticas RLS + set_vet_context()
├── api/
│   ├── index.js               # Servidor Express + endpoints
│   ├── db.js                  # Pool de conexiones multi-rol
│   ├── cache.js               # Cliente Redis (cache-aside)
│   ├── package.json
│   ├── Dockerfile
│   └── .env.example
├── frontend/
│   └── index.html             # 3 pantallas: login, búsqueda, vacunación
└── docker-compose.yml         # PostgreSQL + Redis + API + Frontend
```

## Cómo ejecutar

```bash
# 1. Clonar el repositorio
git clone https://github.com/{usuario}/corte3-bda-{matricula}
cd corte3-bda-{matricula}

# 2. Configurar variables de entorno
# Copia el archivo de ejemplo y ajusta las contraseñas si es necesario
cp .env.example .env

# 3. Levantar todos los servicios
docker-compose up --build

# 4. Acceder al sistema
# Frontend: http://localhost:8081
# API:      http://localhost:3001/api

# Sin Docker (desarrollo local):
cd api
npm install
node index.js
```

> **Nota de seguridad:** El archivo `.env` contiene credenciales sensibles y está excluido de Git por seguridad. Siempre usa `.env.example` como base para nuevas instalaciones.

## Credenciales de prueba

| Usuario | Contraseña | Rol | vet_id |
|---------|-----------|-----|--------|
| vet_lopez | vet_lopez_pass | veterinario | 1 |
| vet_garcia | vet_garcia_pass | veterinario | 2 |
| vet_mendez | vet_mendez_pass | veterinario | 3 |
| usuario_recepcion | recepcion_pass | recepcion | — |
| usuario_admin | admin_pass | admin | — |

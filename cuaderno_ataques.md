# Cuaderno de Ataques — Corte 3 BDA

**Sistema:** Clínica Veterinaria  
**Fecha:** Abril 2026  
**Docente:** Mtro. Ramsés Alejandro Camas Nájera

---

## Sección 1: Tres ataques de SQL Injection que fallan

### Ataque 1 — Quote-escape clásico (OR bypass)

**Input exacto probado:**
```
' OR '1'='1
```

**Pantalla donde se probó:**  
Pantalla de "Búsqueda de Mascotas" → campo de texto "Nombre de mascota".

**Comportamiento esperado sin defensa:**  
La query resultante sería:
```sql
WHERE m.nombre ILIKE '%' OR '1'='1%'
```
Esto devolvería TODAS las mascotas, ignorando el filtro de nombre y potencialmente el filtro de RLS.

**Resultado observado:**  
La API buscó literalmente mascotas con nombre `%' OR '1'='1%`. No se encontraron resultados. La tabla se mostró vacía. No hubo bypass de RLS ni filtros.

**Log del backend:**
```
[2026-04-22T10:15:33Z] GET /api/mascotas?nombre=%27+OR+%271%27%3D%271
[DB] Ejecutando: SELECT ... WHERE m.nombre ILIKE $1  -- params: ["%' OR '1'='1%"]
[DB] Rows returned: 0
```

**Línea exacta que defendió:**  
`api/index.js`, línea ~80:
```javascript
result = await client.query(
    `SELECT ... WHERE m.nombre ILIKE $1 ...`,
    [`%${nombre}%`]   // ← input del usuario nunca entra al string SQL
);
```
El driver `pg` envía el valor como parámetro separado. PostgreSQL lo trata como dato, no como SQL.

---

### Ataque 2 — Stacked query (intento de DROP TABLE)

**Input exacto probado:**
```
Firulais'; DROP TABLE mascotas; --
```

**Pantalla donde se probó:**  
Pantalla de "Búsqueda de Mascotas" → campo de texto "Nombre de mascota".

**Comportamiento esperado sin defensa:**  
En un sistema con concatenación de strings:
```sql
WHERE m.nombre ILIKE '%Firulais'; DROP TABLE mascotas; --%'
```
Ejecutaría `DROP TABLE mascotas` como segundo statement, destruyendo la tabla.

**Resultado observado:**  
La búsqueda buscó literalmente mascotas con nombre `%Firulais'; DROP TABLE mascotas; --%`. Devolvió 0 resultados. La tabla `mascotas` permanece intacta. El segundo statement nunca fue enviado a PostgreSQL porque el protocolo Extended Query solo acepta un statement por mensaje parametrizado.

**Log del backend:**
```
[2026-04-22T10:16:01Z] GET /api/mascotas?nombre=Firulais%27%3B+DROP+TABLE+mascotas%3B+--
[DB] Ejecutando: SELECT ... WHERE m.nombre ILIKE $1  -- params: ["%Firulais'; DROP TABLE mascotas; --%"]
[DB] Rows returned: 0
```

**Línea exacta que defendió:**  
`api/index.js`, línea ~80 — misma defensa que el ataque 1. Los parámetros posicionales hacen imposible el stacked query porque el protocolo wire de PostgreSQL trata el valor como bytes de texto, no como SQL a parsear.

---

### Ataque 3 — UNION-based (extracción de datos de otra tabla)

**Input exacto probado:**
```
' UNION SELECT id, cedula, nombre, NULL, NULL, NULL FROM veterinarios --
```

**Pantalla donde se probó:**  
Pantalla de "Búsqueda de Mascotas" → campo de texto "Nombre de mascota".

**Comportamiento esperado sin defensa:**  
```sql
WHERE m.nombre ILIKE '%' UNION SELECT id, cedula, nombre, NULL, NULL, NULL FROM veterinarios --%'
```
Devolvería todas las cédulas de veterinarios mezcladas con los resultados de mascotas.

**Resultado observado:**  
La búsqueda buscó literalmente ese string en nombres de mascotas. Ninguna mascota tiene ese nombre, resultado: 0 filas. Las cédulas de veterinarios no fueron expuestas.

**Log del backend:**
```
[2026-04-22T10:17:22Z] GET /api/mascotas?nombre=%27+UNION+SELECT+...
[DB] Ejecutando: SELECT ... WHERE m.nombre ILIKE $1
[DB] params: ["%' UNION SELECT id, cedula, nombre, NULL, NULL, NULL FROM veterinarios --%"]
[DB] Rows returned: 0
```

**Línea exacta que defendió:**  
`api/index.js`, línea ~80 — misma defensa. El UNION se convirtió en texto de búsqueda literal.

---

## Sección 2: Demostración de RLS en acción

### Setup

El schema incluye tres veterinarios con mascotas asignadas distintas:

| Veterinario | vet_id | Mascotas asignadas |
|------------|--------|--------------------|
| Dr. Fernando López | 1 | Firulais, Toby, Max |
| Dra. Sofía García | 2 | Misifú, Luna, Dante |
| Dr. Andrés Méndez | 3 | Rocky, Pelusa, Coco, Mango |

### Demo: Dr. López (vet_id=1) consulta "todas las mascotas"

**Acción:** Login como `vet_lopez`, pantalla Mascotas → botón "Ver Todas".

**Resultado:**  
Solo aparecen 3 mascotas: Firulais, Toby, Max.  
No aparecen Misifú, Luna, Dante, Rocky, Pelusa, Coco ni Mango.

**Log del backend:**
```
[2026-04-22T10:20:15Z] GET /api/mascotas
[RLS] SET LOCAL app.current_vet_id = '1'
[DB] SELECT ... FROM mascotas m JOIN duenos d ...
[DB] Rows returned: 3  (Firulais, Toby, Max)
```

### Demo: Dra. García (vet_id=2) hace la misma consulta

**Acción:** Login como `vet_garcia`, pantalla Mascotas → botón "Ver Todas".

**Resultado:**  
Solo aparecen 3 mascotas: Misifú, Luna, Dante.  
Las mascotas de López y Méndez no aparecen.

**Log del backend:**
```
[2026-04-22T10:21:30Z] GET /api/mascotas
[RLS] SET LOCAL app.current_vet_id = '2'
[DB] SELECT ... FROM mascotas m JOIN duenos d ...
[DB] Rows returned: 3  (Misifú, Luna, Dante)
```

### Admin ve todo

**Acción:** Login como `usuario_admin`, pantalla Mascotas → "Ver Todas".

**Resultado:** 10 mascotas — todas las del sistema.

### Política RLS que produce este comportamiento

```sql
CREATE POLICY pol_mascotas_vet ON mascotas FOR ALL TO rol_veterinario
    USING (
        id IN (
            SELECT mascota_id FROM vet_atiende_mascota
            WHERE vet_id = current_setting('app.current_vet_id', true)::INT
              AND activa = TRUE
        )
    );
```

Antes de devolver cada fila de `mascotas`, PostgreSQL evalúa si `mascotas.id` aparece en `vet_atiende_mascota` para el `vet_id` de la sesión actual. Si no aparece, la fila no llega al cliente — es como si no existiera.

---

## Sección 3: Demostración de caché Redis

### Secuencia de logs con timestamps

```
# PRIMERA CONSULTA — CACHE MISS
[2026-04-22T10:30:00.001Z] GET /api/vacunacion-pendiente
[CACHE] Buscando clave "vacunacion_pendiente" en Redis...
[CACHE MISS] vacunacion_pendiente — BD consultada en 187ms
[CACHE SET] "vacunacion_pendiente" guardado con TTL=300s

# SEGUNDA CONSULTA INMEDIATA — CACHE HIT
[2026-04-22T10:30:02.543Z] GET /api/vacunacion-pendiente
[CACHE] Buscando clave "vacunacion_pendiente" en Redis...
[CACHE HIT] vacunacion_pendiente — latencia 8ms

# TERCERA CONSULTA (también HIT mientras TTL no expire)
[2026-04-22T10:30:10.112Z] GET /api/vacunacion-pendiente
[CACHE HIT] vacunacion_pendiente — latencia 6ms

# POST: se aplica una vacuna → invalidación explícita
[2026-04-22T10:30:45.678Z] POST /api/vacunas-aplicadas
[DB] INSERT INTO vacunas_aplicadas ... (id=10)
[CACHE DEL] "vacunacion_pendiente" eliminado del caché (invalidación explícita)

# CUARTA CONSULTA (después de invalidación) — CACHE MISS de nuevo
[2026-04-22T10:30:47.901Z] GET /api/vacunacion-pendiente
[CACHE] Buscando clave "vacunacion_pendiente" en Redis...
[CACHE MISS] vacunacion_pendiente — BD consultada en 203ms
[CACHE SET] "vacunacion_pendiente" guardado con TTL=300s
```

### Resumen de decisiones de caché

| Parámetro | Valor | Justificación |
|-----------|-------|---------------|
| **Key** | `vacunacion_pendiente` | Clave simple y descriptiva. Si en el futuro se cachea por vet, sería `vacunacion_pendiente:vet_1`. |
| **TTL** | 300 segundos (5 min) | Equilibrio entre frescura y rendimiento. Las vacunaciones son eventos poco frecuentes (~5-10 al día en una clínica pequeña). |
| **Estrategia de invalidación** | Invalidación explícita por escritura | Cuando `POST /api/vacunas-aplicadas` tiene éxito, `deleteCache('vacunacion_pendiente')` se llama inmediatamente. No esperamos que el TTL expire. |

**Por qué invalidación explícita y no solo TTL:**  
Si alguien vacuna a Firulais a las 10:30 y el TTL no expiró hasta las 10:35, la pantalla mostraría a Firulais como "pendiente" durante esos 5 minutos aunque la vacuna ya fue aplicada. Con invalidación explícita, la siguiente consulta después del POST siempre va a BD y obtiene datos frescos.

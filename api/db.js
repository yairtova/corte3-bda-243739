// =============================================================
// api/db.js — Pool de conexiones PostgreSQL
//
// Un pool por rol de BD. Cada rol tiene su usuario PostgreSQL
// con los permisos correspondientes (definidos en 04_roles.sql).
// Cuando llega una request, getClientForRole() elige el pool
// correcto según el rol de la sesión HTTP.
// =============================================================

const { Pool } = require('pg');

const BASE_CONFIG = {
    host:     process.env.DB_HOST     || 'localhost',
    port:     parseInt(process.env.DB_PORT || '5432', 10),
    database: process.env.DB_NAME     || 'clinica_vet',
};

// Pool para cada rol de PostgreSQL
const pools = {
    veterinario: new Pool({
        ...BASE_CONFIG,
        user:     process.env.DB_USER_VET  || 'vet_lopez',   // user genérico del rol
        password: process.env.DB_PASS_VET  || 'vet_lopez_pass',
        // El vet_id real se establece con SET LOCAL en cada TX (RLS)
    }),
    recepcion: new Pool({
        ...BASE_CONFIG,
        user:     process.env.DB_USER_REC  || 'usuario_recepcion',
        password: process.env.DB_PASS_REC  || 'recepcion_pass',
    }),
    admin: new Pool({
        ...BASE_CONFIG,
        user:     process.env.DB_USER_ADM  || 'usuario_admin',
        password: process.env.DB_PASS_ADM  || 'admin_pass',
    }),
};

// Pool de admin también para queries sin rol específico (ej. /api/veterinarios)
const pool = pools.admin;

// Mapa de usuarios veterinarios (vet_id -> credenciales de BD)
// En producción esto podría venir de variables de entorno o Vault.
const VET_USERS = {
    1: { user: process.env.DB_USER_VET1 || 'vet_lopez',  password: process.env.DB_PASS_VET1 || 'vet_lopez_pass' },
    2: { user: process.env.DB_USER_VET2 || 'vet_garcia', password: process.env.DB_PASS_VET2 || 'vet_garcia_pass' },
    3: { user: process.env.DB_USER_VET3 || 'vet_mendez', password: process.env.DB_PASS_VET3 || 'vet_mendez_pass' },
};

// Cache de pools por vet_id para no crear uno nuevo en cada request
const vetPools = {};

/**
 * Retorna un cliente de BD apropiado para el rol dado.
 * Para veterinarios, usa el pool del usuario específico de ese vet.
 * @param {string} role - 'veterinario' | 'recepcion' | 'admin'
 * @param {number|null} vetId - ID del veterinario (solo cuando role=veterinario)
 */
async function getClientForRole(role, vetId = null) {
    if (role === 'veterinario') {
        const creds = VET_USERS[vetId];
        if (!creds) throw new Error(`No hay usuario de BD configurado para vet_id=${vetId}`);

        // Crear pool para este vet si no existe
        if (!vetPools[vetId]) {
            vetPools[vetId] = new Pool({ ...BASE_CONFIG, ...creds });
        }
        return vetPools[vetId].connect();
    }

    const targetPool = pools[role] || pools.admin;
    return targetPool.connect();
}

module.exports = { pool, getClientForRole };

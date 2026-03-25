import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

import express from 'express';

export const router = express.Router();

const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB
const CACHE_MAX_AGE = 604800; // 7 days in seconds
const CACHE_DIR_NAME = 'cache/images';

/** @type {Map<string, Promise<{filePath: string, contentType: string}>>} */
const inFlightRequests = new Map();

/**
 * Get the cache directory for the current user.
 * @param {import('express').Request} request
 * @returns {string}
 */
function getCacheDir(request) {
    const userDir = request.user.directories.root;
    return path.resolve(userDir, CACHE_DIR_NAME);
}

/**
 * Compute SHA256 hash of a URL string.
 * @param {string} url
 * @returns {string}
 */
function hashUrl(url) {
    return crypto.createHash('sha256').update(url).digest('hex');
}

/**
 * Validate that the URL is a safe external HTTP(S) URL.
 * @param {string} url
 * @returns {boolean}
 */
function isValidExternalUrl(url) {
    try {
        const parsed = new URL(url);
        return parsed.protocol === 'http:' || parsed.protocol === 'https:';
    } catch {
        return false;
    }
}

/**
 * Fetch and cache an image from external URL.
 * @param {string} url The external image URL
 * @param {string} cacheDir The cache directory path
 * @param {string} hash The URL hash for cache key
 * @returns {Promise<{filePath: string, contentType: string}>}
 */
async function fetchAndCache(url, cacheDir, hash) {
    const response = await fetch(url, {
        headers: {
            'User-Agent': 'Mozilla/5.0 (compatible; SillyTavern Image Proxy)',
            'Accept': 'image/*,*/*;q=0.8',
        },
        signal: AbortSignal.timeout(30000),
    });

    if (!response.ok) {
        throw new Error(`Remote server returned ${response.status} ${response.statusText}`);
    }

    const contentType = response.headers.get('content-type') || 'application/octet-stream';
    const contentLength = parseInt(response.headers.get('content-length') || '0', 10);

    if (contentLength > MAX_FILE_SIZE) {
        throw new Error(`File too large: ${contentLength} bytes (max ${MAX_FILE_SIZE})`);
    }

    const buffer = Buffer.from(await response.arrayBuffer());

    if (buffer.length > MAX_FILE_SIZE) {
        throw new Error(`File too large: ${buffer.length} bytes (max ${MAX_FILE_SIZE})`);
    }

    // Ensure cache directory exists
    fs.mkdirSync(cacheDir, { recursive: true });

    // Determine file extension from content type
    const ext = contentType.includes('png') ? '.png'
        : contentType.includes('jpeg') || contentType.includes('jpg') ? '.jpg'
        : contentType.includes('gif') ? '.gif'
        : contentType.includes('webp') ? '.webp'
        : contentType.includes('svg') ? '.svg'
        : contentType.includes('avif') ? '.avif'
        : contentType.includes('bmp') ? '.bmp'
        : '';

    const filePath = path.join(cacheDir, hash + ext);

    // Write image data
    fs.writeFileSync(filePath, buffer);

    // Write metadata
    const metaPath = path.join(cacheDir, hash + '.meta.json');
    fs.writeFileSync(metaPath, JSON.stringify({
        url: url,
        contentType: contentType,
        size: buffer.length,
        cachedAt: new Date().toISOString(),
    }));

    return { filePath, contentType };
}

/**
 * Find a cached file by hash (any extension).
 * @param {string} cacheDir
 * @param {string} hash
 * @returns {{ filePath: string, contentType: string } | null}
 */
function findCachedFile(cacheDir, hash) {
    const metaPath = path.join(cacheDir, hash + '.meta.json');
    if (!fs.existsSync(metaPath)) {
        return null;
    }

    try {
        const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));
        const contentType = meta.contentType || 'application/octet-stream';

        // Find the actual image file (hash + extension)
        const files = fs.readdirSync(cacheDir);
        const imageFile = files.find(f => f.startsWith(hash) && !f.endsWith('.meta.json'));
        if (!imageFile) {
            return null;
        }

        return {
            filePath: path.join(cacheDir, imageFile),
            contentType: contentType,
        };
    } catch {
        return null;
    }
}

router.get('/', async function (request, response) {
    const url = request.query.url;

    if (!url || typeof url !== 'string') {
        return response.status(400).send('Missing url parameter');
    }

    if (!isValidExternalUrl(url)) {
        return response.status(400).send('Invalid URL: must be http or https');
    }

    const cacheDir = getCacheDir(request);
    const hash = hashUrl(url);

    try {
        // Check disk cache first
        const cached = findCachedFile(cacheDir, hash);
        if (cached) {
            response.setHeader('Content-Type', cached.contentType);
            response.setHeader('Cache-Control', `public, max-age=${CACHE_MAX_AGE}`);
            response.setHeader('X-Image-Cache', 'HIT');
            return response.sendFile(cached.filePath);
        }

        // Deduplicate concurrent requests for the same URL
        let fetchPromise = inFlightRequests.get(url);
        if (!fetchPromise) {
            fetchPromise = fetchAndCache(url, cacheDir, hash);
            inFlightRequests.set(url, fetchPromise);
            fetchPromise.finally(() => inFlightRequests.delete(url));
        }

        const result = await fetchPromise;
        response.setHeader('Content-Type', result.contentType);
        response.setHeader('Cache-Control', `public, max-age=${CACHE_MAX_AGE}`);
        response.setHeader('X-Image-Cache', 'MISS');
        return response.sendFile(result.filePath);
    } catch (error) {
        console.error(`Image proxy error for ${url}:`, error.message);
        return response.status(502).send(`Failed to fetch image: ${error.message}`);
    }
});

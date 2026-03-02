import { parseIP } from './iputil'

/**
 * Looks up a domain using the native DNS resolver.
 * @param {string} domain - The domain to look up.
 * @returns {Promise<{
 *   resolvedAddress: string | null;
 * }>} - The result from the native DNS resolver.
 */
async function doNativeLookup(domain) {
  try {
    /**
     * @type {{
     *   error: string | null;
     *   resolvedAddress: string | null;
     * }}
     */
    const result = await browser.runtime.sendNativeMessage('', {
      cmd: 'lookup',
      domain,
    })

    VERBOSE5: console.log(
      'Native lookup result:',
      'domain=' + domain,
      'resolvedAddress=' + result.resolvedAddress
    )

    if (result.error) {
      throw new Error(result.error)
    } else {
      return result
    }
  } catch (error) {
    VERBOSE2: console.warn(
      'Native lookup error:',
      'error',
      error,
      'domain',
      domain
    )
    
    // Fallback: Native app blocks some lookups (e.g. localhost)
    // If domain is already an IP address, return it directly
    try {
      let cleanDomain = domain
      
      // Remove IPv6 brackets if present
      if (
        typeof domain === 'string' &&
        domain.startsWith('[') &&
        domain.endsWith(']')
      ) {
        cleanDomain = domain.slice(1, -1)
      }
      
      // Validate it's a real IP address
      try {
        parseIP(cleanDomain)
        VERBOSE3: console.log(
          'Domain is already an IP address, returning as-is:',
          domain
        )
        return {
          resolvedAddress: domain,
        }
      } catch (e) {
        VERBOSE3: console.log('Lookup failed for non-IP domain:', domain)
        return null
      }
    } catch {
      VERBOSE3: console.log('Unexpected error handling domain:', domain)
      return null
    }
  }
}

// DNS caching and deduplication
// ================================
// When a page loads, multiple requests to the same domain arrive simultaneously.
// Without caching/deduplication, each triggers a separate native DNS lookup.
//
// Two-layer strategy:
// 1. inflightLookups: Deduplicate concurrent requests for same domain
//    - First request starts lookup, subsequent requests wait for same promise
// 2. dnsCache: Cache completed lookups for 10 seconds
//    - Avoid repeated lookups when browsing same site
//
// Technically, the cache is not necessary because these requests
// are so close together, its extremely likely they will hit
// system DNS cache. This is simply a performance optimization
// to avoid making repeated requests to the native app. 
// Which have a very tiny latency associated with them.

/** @type {Map<string, {ip: string, timestamp: number}>} */
const dnsCache = new Map()
const DNS_CACHE_TTL = 10 * 1000 // 10 seconds

/** @type {Map<string, Promise<string>>} */
const inflightLookups = new Map()

// Clean up expired cache entries every 10 seconds
setInterval(() => {
  const now = Date.now()
  for (const [key, entry] of dnsCache.entries()) {
    if (now - entry.timestamp >= DNS_CACHE_TTL) {
      dnsCache.delete(key)
      VERBOSE3: console.log('DNS cache entry expired for', key)
    }
  }
}, DNS_CACHE_TTL)

/**
 * Resolves a domain to an IP address using native DNS with caching and deduplication.
 * 
 * @param {string} domain - The domain to look up.
 * @returns {Promise<string>} - The resolved IP address.
 */
export async function resolveDomainViaNativeWithCache(domain) {
  const now = Date.now()
  
  // Check cached result first
  const cacheEntry = dnsCache.get(domain)
  if (cacheEntry && now - cacheEntry.timestamp < DNS_CACHE_TTL) {
    VERBOSE3: console.log('cache hit for', domain)
    return cacheEntry.ip
  }

  // Check if lookup already in progress for this domain
  const inflightPromise = inflightLookups.get(domain)
  if (inflightPromise) {
    VERBOSE3: console.log('in-flight lookup already in progress for', domain)
    return inflightPromise
  }

  // Start new lookup and track it to deduplicate parallel requests
  const lookupPromise = performLookup(domain)
  inflightLookups.set(domain, lookupPromise)
  return lookupPromise
}

/**
 * Performs the actual DNS lookup and caches the result.
 * Cleans up in-flight tracking when complete.
 * 
 * @param {string} domain - The domain to look up.
 * @returns {Promise<string>} - The resolved IP address.
 */
async function performLookup(domain) {
  try {
    const result = await doNativeLookup(domain)
    const address = result?.resolvedAddress ?? null

    if (address) {
      dnsCache.set(domain, {
        ip: address,
        timestamp: Date.now(),
      })
      VERBOSE3: console.log(
        'result cached for',
        'domain=' + domain,
        'address=' + address
      )
    }

    return address
  } finally {
    // Remove from in-flight tracking when done (success or failure)
    inflightLookups.delete(domain)
  }
}
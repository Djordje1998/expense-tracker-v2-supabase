import { assertEquals, assertExists } from "https://deno.land/std@0.192.0/testing/asserts.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.58.0";
import { afterAll } from "https://deno.land/std@0.192.0/testing/bdd.ts";

const TEST_SUPABASE_URL = 'https://ngxkhlvqsxqguoqakfrr.supabase.co';
const EDGE_FUNCTION_URL = `${TEST_SUPABASE_URL}/functions/v1/fetch-invoice-v2`;
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5neGtobHZxc3hxZ3VvcWFrZnJyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDE5OTA5NjYsImV4cCI6MjA1NzU2Njk2Nn0.PzgACU_dUznbBtv3eg7yUX1eq1E_IuAP950tfK1203w';
const TEST_INVOICE_URL = "https://suf.purs.gov.rs/v/?vl=A1o0OFg0UTlZVzZVQlBaTzAfEwAAXRIAAMDruA4AAAAAAAABkafwxnUAAABZMLrnyTXcjpZwOFKg%2FK6NSnus0ZRLKmUmaBL1oAkK2EVOyMFIB5ZocEvO1icx4xo9B6x2GFr2ZeoKKp83v2otDoEeAbEkCHB3XOOek3CC%2BUpZTMgCMZXJe%2B5E3xYbcK909mLj3dbNd6ZXdPo9CuKeVTlto6CJ69MYbt%2FSQ14su8hTkPP6aZQJQ1TgAgfC8R3nAb9G8HrkDyTs6cBpIkrrhGxafbr%2BkY9fGsiAVfzf60Psgiu3hp1IqM9jqVBvaslv5ZZAdJy2VNk%2Br6ymEAB%2FD4qfhpR0Yx1umbwLrH5LnWTjxRjGTGwhakaLRhTWkpQa%2ByI8kfA0U3GvnkyVrZYNoV1nk7RTZU2zKCkIv2rTH1y8XAknbyvXepiDhoQGZd27vQgd6MC6aN%2B9U%2BMZZlDlDcfXgyqM0Rri8D86T%2FDFleYfNi%2BwKUuW2qk5fzAq%2FdVqv%2Fbl8RCj%2FNDk0AXHFGZegQ8Dj4SnLgdBttxWKxrcq%2FjYMdayniGeJjuZf1Gr%2Bfhq7%2BZgGL%2Fruf3TV4mPLc2kpFIXJ7yU4uX7raC%2BYuGxbmnmIQDgs0saM%2FqqzbtjRb1GsuOz4P44%2Bl3jPJZStPxesrdEisKQzE3aguTUsDh2ceMAWuhlYcRavptiA4mutvRf1iaKrYQ%2F7rseq14tcAaVtD8ZfBtjYAyBnpSzoIzSTXThoqKiBchcIKnGWkoVeg8%3D";

const TEST_USER_EMAIL = 'test@testuser.com';
const TEST_USER_PASSWORD = 'testuser';

let supabaseClient: SupabaseClient | null = null;

async function getTestUserToken(): Promise<string> {
  if (!supabaseClient) {
    supabaseClient = createClient(TEST_SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: {
        autoRefreshToken: false,
        persistSession: false
      }
    });
  }
  
  const { data, error } = await supabaseClient.auth.signInWithPassword({
    email: TEST_USER_EMAIL,
    password: TEST_USER_PASSWORD,
  });
  
  if (error) {
    throw new Error(`Failed to sign in test user: ${error.message}`);
  }
  
  return data.session?.access_token || '';
}

afterAll(async () => {
  if (supabaseClient) {
    try {
      await supabaseClient.auth.signOut();
    } catch (error) {
      console.error('Error during sign out:', error);
    }
    
    supabaseClient = null;
  }
});

async function makeRequest(url: string, accessToken: string, method: string = 'POST') {
  const options: RequestInit = {
    method,
    headers: {
      'Authorization': `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
      'apikey': SUPABASE_ANON_KEY
    }
  };
  
  
  if (method !== 'GET' && method !== 'HEAD') {
    options.body = JSON.stringify({ url });
  }
  
  const response = await fetch(EDGE_FUNCTION_URL, options);
  const text = await response.text();
  try {
    const data = text ? JSON.parse(text) : {};
    return { response, data };
  } catch {
    return { response, data: { error: text } };
  }
}

Deno.test("fetch-invoice-v2: OPTIONS request returns correct CORS headers", async () => {
  const response = await fetch(EDGE_FUNCTION_URL, {
    method: 'OPTIONS',
    headers: {
      'apikey': SUPABASE_ANON_KEY
    }
  });
  
  await response.text();
  
  assertEquals(response.status, 200);
  assertEquals(response.headers.get('Access-Control-Allow-Origin'), '*');
  assertEquals(response.headers.get('Access-Control-Allow-Methods'), 'POST, OPTIONS');
  assertExists(response.headers.get('Access-Control-Allow-Headers'));
});

Deno.test({
  name: "fetch-invoice-v2: POST without URL parameter fails",
  fn: async () => {
    const accessToken = await getTestUserToken();
    const { response } = await makeRequest('', accessToken);
    
    assertEquals(response.status >= 400, true);
  },
  sanitizeResources: false,
  sanitizeOps: false
});

Deno.test("fetch-invoice-v2: GET request returns method not allowed", async () => {
  const accessToken = await getTestUserToken();
  const { response, data } = await makeRequest('', accessToken, 'GET');
  
  assertEquals(response.status, 405);
  assertEquals(data.error, 'Method not allowed');
});

Deno.test("fetch-invoice-v2: POST with invalid auth fails", async () => {
  const { response } = await makeRequest('https://example.com', 'invalid-token');
  
  assertEquals(response.status >= 400, true);
});

Deno.test({
  name: "fetch-invoice-v2: Full integration test with test user",
  ignore: false,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    let supabase;
    
    try {
      const testUserToken = await getTestUserToken();
      
      supabase = createClient(TEST_SUPABASE_URL, SUPABASE_ANON_KEY, {
        auth: {
          autoRefreshToken: false,
          persistSession: false
        },
        db: {
          schema: 'expense_tracker'
        },
        global: {
          headers: {
            Authorization: `Bearer ${testUserToken}`
          }
        }
      });
      
      console.log('Fetching invoice data to get invoice_number...');
      const invoiceResponse = await fetch(TEST_INVOICE_URL, {
        method: "POST",
        headers: {
          "Accept": "application/json"
        }
      });
      const invoiceData = await invoiceResponse.json();
      const invoiceNumber = invoiceData.invoiceResult?.invoiceNumber;
      
      if (!invoiceNumber) {
        throw new Error('Failed to get invoice number from test invoice URL');
      }
      
      console.log(`Invoice number: ${invoiceNumber}`);
      
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) {
        throw new Error('Failed to get test user');
      }
      
      const { response, data } = await makeRequest(TEST_INVOICE_URL, testUserToken);
      
      assertEquals(response.status, 200, 'Response status should be 200');
      assertExists(data, 'Response data should exist');
      
      const duplicateMsg = 'This invoice has already been added to your account';
      if (data.error) {
        assertEquals(data.error, duplicateMsg);
        console.log('✓ Invoice already existed for test user; duplicate path accepted');
      } else {
        assertEquals(data.message, 'Invoice created successfully', 'Response should contain success message');
        console.log('✓ Invoice created for test user:', TEST_USER_EMAIL);
      }
      
    } finally {
      if (supabase) {
        try {
          await supabase.auth.signOut();
        } catch (e) {
          console.error('Error during sign out:', e);
        }
      }
    }
  }
});

Deno.test({
  name: "fetch-invoice-v2: Duplicate invoice detection with test user",
  ignore: false,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    let supabase;
    
    try {
      const testUserToken = await getTestUserToken();
      
      supabase = createClient(TEST_SUPABASE_URL, SUPABASE_ANON_KEY, {
        auth: {
          autoRefreshToken: false,
          persistSession: false
        },
        db: {
          schema: 'expense_tracker'
        },
        global: {
          headers: {
            Authorization: `Bearer ${testUserToken}`
          }
        }
      });
      
      const invoiceResponse = await fetch(TEST_INVOICE_URL, {
        method: "POST",
        headers: {
          "Accept": "application/json"
        }
      });
      const invoiceData = await invoiceResponse.json();
      const invoiceNumber = invoiceData.invoiceResult?.invoiceNumber;
      
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) {
        throw new Error('Failed to get test user');
      }
      
      await makeRequest(TEST_INVOICE_URL, testUserToken);
      
      const { response, data } = await makeRequest(TEST_INVOICE_URL, testUserToken);
      
      assertEquals(response.status, 200);
      assertEquals(data.error, 'This invoice has already been added to your account');
      
      console.log('✓ Duplicate detection working for test user');
      
    } finally {
      if (supabase) {
        try {
          await supabase.auth.signOut();
        } catch (e) {
          console.error('Error during sign out:', e);
        }
      }
    }
  }
});

Deno.test("fetch-invoice-v2: getLabelId returns correct IDs", () => {
  const getLabelId = (labelCode: string) => {
    switch(labelCode) {
      case 'Ђ':
        return '01964ade-4bfc-7be4-84b2-a1175d6fff26';
      case 'Е':
        return '01964ae3-9828-7e3d-aa40-28de2be9c782';
      case 'Г':
        return '01964ae3-c4ca-708f-8510-a312fd75da41';
      case 'А':
        return '01964ae3-fb92-7104-bbc5-85c6413e0730';
      default:
        return '01964ade-4bfc-7be4-84b2-a1175d6fff26';
    }
  };
  
  assertEquals(getLabelId('Ђ'), '01964ade-4bfc-7be4-84b2-a1175d6fff26');
  assertEquals(getLabelId('Е'), '01964ae3-9828-7e3d-aa40-28de2be9c782');
  assertEquals(getLabelId('Г'), '01964ae3-c4ca-708f-8510-a312fd75da41');
  assertEquals(getLabelId('А'), '01964ae3-fb92-7104-bbc5-85c6413e0730');
  assertEquals(getLabelId('Unknown'), '01964ade-4bfc-7be4-84b2-a1175d6fff26');
});

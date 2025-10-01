import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
Deno.serve(async (req)=>{
  console.log("================= Parse invoice data edge function =================");
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type, x-client-info, apikey',
    'Content-Type': 'application/json'
  };
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers
    });
  }
  if (req.method === 'POST') {
    const { url } = await req.json();
    console.log(">>> url: " + url);
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), {
      db: {
        schema: 'expense_tracker'
      },
      global: {
        headers: {
          Authorization: req.headers.get('Authorization')
        }
      }
    });
    const token = req.headers.get('Authorization')?.replace('Bearer ', '');
    const userResponse = await supabase.auth.getUser(token);
    console.log("supabase.auth.getUser", userResponse.data, userResponse.error);
    const user = userResponse.data.user;
    console.log("user.id", user.id);
    const invoiceResponse = await fetch(url, {
      method: "POST",
      headers: {
        "Accept": "application/json"
      }
    });
    const invoice = await invoiceResponse.json();
    console.log(">>> invoice.journal: " + invoice.journal);
    try {
      // Check if company exists
      const { data: existingCompany, error: companyError } = await supabase.from('company').select('id').eq('tax_id', invoice.invoiceRequest.taxId).eq('location_name', invoice.invoiceRequest.locationName).maybeSingle();
      console.log(">>> company check", existingCompany, companyError);
      let companyId;
      if (companyError) {
        console.error('Error checking company:', companyError);
        return new Response(JSON.stringify({
          error: 'Failed to check company'
        }), {
          headers,
          status: 500
        });
      }
      if (!existingCompany) {
        // Create company
        const { data: newCompany, error: createError } = await supabase.from('company').insert([
          {
            tax_id: invoice.invoiceRequest.taxId,
            business_name: invoice.invoiceRequest.businessName,
            location_name: invoice.invoiceRequest.locationName,
            city: invoice.invoiceRequest.city,
            administrative_unit: invoice.invoiceRequest.administrativeUnit,
            address: invoice.invoiceRequest.address
          }
        ]).select('id').single();
        if (createError) {
          console.error('Error creating company:', createError);
          return new Response(JSON.stringify({
            error: 'Failed to create company'
          }), {
            headers,
            status: 500
          });
        }
        companyId = newCompany.id;
        console.log(">>> created new company with id:", companyId);
      } else {
        companyId = existingCompany.id;
        console.log(">>> using existing company with id:", companyId);
      }
      // Fetch the specifications data before starting transaction
      const response = await fetch(url);
      const htmlText = await response.text();
      const match = htmlText.match(/token\(['"]([a-f0-9\-]{36})['"]\)/i);
      const tokenSUF = match ? match[1] : null;
      console.log(">>> tokenSUF from html: ", tokenSUF);
      const rawBody = 'invoiceNumber=' + invoice.invoiceResult.invoiceNumber + '&token=' + tokenSUF;
      console.log(">>> rawBody: ", rawBody);
      const res = await fetch('https://suf.purs.gov.rs/specifications', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'
        },
        body: rawBody
      });
      const responseText = await res.text();
      console.log(">>> responseText: ", responseText);
      // Parse the responseText as JSON
      const parsedResponse = JSON.parse(responseText);
      // Begin transaction for invoice and invoice items
      const { data: transactionData, error: transactionError } = await supabase.rpc('create_invoice_with_items', {
        invoice_data: {
          invoice_number: invoice.invoiceResult.invoiceNumber,
          invoice_url: url,
          journal: invoice.journal,
          total_amount: invoice.invoiceResult.totalAmount,
          invoice_type: invoice.invoiceRequest.invoiceType,
          transaction_type: invoice.invoiceRequest.transactionType,
          counter_extension: invoice.invoiceResult.invoiceCounterExtension,
          transaction_type_counter: invoice.invoiceResult.transactionTypeCounter,
          counter_total: invoice.invoiceResult.totalCounter,
          requested_by: invoice.invoiceRequest.requestedBy,
          signed_by: invoice.invoiceResult.signedBy,
          pft_time: invoice.invoiceResult.sdcTime,
          is_valid: invoice.isValid,
          note: null,
          user_id: user.id,
          company_id: companyId,
          currency_code: 'RSD'
        },
        invoice_items: parsedResponse.success && Array.isArray(parsedResponse.items) ? parsedResponse.items.map((item, index)=>{
          // Function to get label ID from label code (static mapping)
          const getLabelId = (labelCode)=>{
            switch(labelCode){
              case 'Ђ':
                return '01964ade-4bfc-7be4-84b2-a1175d6fff26'; // 20% VAT
              case 'Е':
                return '01964ae3-9828-7e3d-aa40-28de2be9c782'; // 10% VAT
              case 'Г':
                return '01964ae3-c4ca-708f-8510-a312fd75da41'; // 0% VAT
              case 'А':
                return '01964ae3-fb92-7104-bbc5-85c6413e0730'; // 0% VAT
              default:
                return '01964ade-4bfc-7be4-84b2-a1175d6fff26'; // Default to 20% VAT
            }
          };
          return {
            item_order: index + 1,
            name: item.name,
            unit_price: item.unitPrice,
            quantity: item.quantity,
            total: item.total,
            tax_base_amount: item.taxBaseAmount,
            vat_amount: item.vatAmount,
            description: null,
            label_id: getLabelId(item.label),
            category_id: null // Category needs to be set later by the user
          };
        }) : []
      });
      if (transactionError) {
        console.error('Error in transaction:', transactionError);
        // Check for duplicate invoice error
        if (transactionError.code === '23505' && transactionError.message?.includes('invoice_user_id_invoice_number_key')) {
          return new Response(JSON.stringify({
            error: 'This invoice has already been added to your account',
            code: transactionError.code,
            details: transactionError.message
          }), {
            headers,
            status: 200
          });
        }
        return new Response(JSON.stringify({
          error: 'Failed to create invoice and items in transaction'
        }), {
          headers,
          status: 500
        });
      }
      console.log(">>> Transaction result:", transactionData);
    } catch (error) {
      console.error('Error processing invoice and items:', error);
      return new Response(JSON.stringify({
        error: 'Failed to process invoice and items'
      }), {
        headers,
        status: 500
      });
    }
    return new Response(JSON.stringify({
      message: 'Invoice created successfully'
    }), {
      headers,
      status: 200
    });
  }
  return new Response(JSON.stringify({
    error: 'Method not allowed'
  }), {
    headers,
    status: 405
  });
});

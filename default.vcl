# Marker to tell the VCL compiler that this VCL has been adapted to the
# new 4.0 format.
vcl 4.0;

# Import VMod's
import std;
import directors;

# Default backend definition. Set this to point to your content server.
backend default {
  .host = "localhost";
  .port = "81";
  .connect_timeout = 600s;
  .first_byte_timeout = 600s;
  .between_bytes_timeout = 600s;
  .max_connections = 300;
}

# Only allow purging from specific IPs
acl purge {
  "localhost";
  "127.0.0.1";
  "::1";
}

acl internal {
  "127.0.0.0"/24;
  # For remote access, add your IP address here.
  # Ex: 162.xxx.xx.xx
}

# This function is used when a request is send by a HTTP client (Browser) 
sub vcl_recv {
  # Normalize the header, remove the port (in case you're testing this on various TCP ports)
  set req.http.Host = regsub(req.http.Host, ":[0-9]+", "");

  # Normalize the query arguments
  set req.url = std.querysort(req.url);

  # Check if request is allowed to invoke cache purge, Allow purging.
  if (req.method == "PURGE") {
    if (!client.ip ~ purge) { 
      # purge is the ACL defined at the begining
      # Not from an allowed IP? Then die with an error.
      return (synth(405, "Forbidden - Not allowed."));
    }
    # If you got this stage (and didn't error out above), purge the cached result.
    return (purge);
  }

  # Verify HTTP request methods
  # Only deal with "normal" types.
  if (req.method != "GET" &&
      req.method != "HEAD" &&
      req.method != "PUT" &&
      req.method != "POST" &&
      req.method != "TRACE" &&
      req.method != "OPTIONS" &&
      req.method != "PATCH" &&
      req.method != "DELETE") {
    /* Non-RFC2616 or CONNECT which is weird. */
    return (pipe);
  }

  # Implementing websocket support (https://www.varnish-cache.org/docs/4.0/users-guide/vcl-example-websockets.html)
  if (req.http.Upgrade ~ "(?i)websocket") {
    return (pipe);
  }

  # Only cache GET or HEAD requests. This makes sure the POST requests are always passed.
  if (req.method != "GET" && req.method != "HEAD") {
    /* We only deal with GET and HEAD by default */
    return (pass);
  }

  #if (req.http.Authorization || req.http.Cookie) {
    /* Not cacheable by default */
    #return (pass);
  #}

  # Some generic URL manipulation, useful for all templates that follow
  # First remove the Google Analytics added parameters, useless for our backend
  if (req.url ~ "(\?|&)(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=") {
    set req.url = regsuball(req.url, "&(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "");
    set req.url = regsuball(req.url, "\?(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "?");
    set req.url = regsub(req.url, "\?&", "?");
    set req.url = regsub(req.url, "\?$", "");
  }

  # Strip hash, server doesn't need it.
  if (req.url ~ "\#") {
    set req.url = regsub(req.url, "\#.*$", "");
  }

  # Strip a trailing ? if it exists
  if (req.url ~ "\?$") {
    set req.url = regsub(req.url, "\?$", "");
  }

  # Some generic cookie manipulation, useful for all templates that follow
  # Remove the "has_js" cookie
  set req.http.Cookie = regsuball(req.http.Cookie, "has_js=[^;]+(; )?", "");

  # Remove any Google Analytics based cookies
  set req.http.Cookie = regsuball(req.http.Cookie, "__utm.=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "_ga=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "_gat=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "utmctr=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "utmcmd.=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "utmccn.=[^;]+(; )?", "");

  # Remove DoubleClick offensive cookies
  set req.http.Cookie = regsuball(req.http.Cookie, "__gads=[^;]+(; )?", "");

  # Remove the Quant Capital cookies (added by some plugin, all __qca)
  set req.http.Cookie = regsuball(req.http.Cookie, "__qc.=[^;]+(; )?", "");

  # Remove the AddThis cookies
  set req.http.Cookie = regsuball(req.http.Cookie, "__atuv.=[^;]+(; )?", "");

  # Remove a ";" prefix in the cookie if present
  set req.http.Cookie = regsuball(req.http.Cookie, "^;\s*", "");
  
  # Remove any Piiwik based cookies
  set req.http.Cookie = regsuball(req.http.Cookie, "(^|;\s*)(_pk_(ses|id)[\.a-z0-9]*)=[^;]*", ""); # removes Piwik cookies


  # Are there cookies left with only spaces or that are empty?
  if (req.http.cookie ~ "^\s*$") {
    unset req.http.cookie;
  }

  #if (req.http.Cache-Control ~ "(?i)no-cache") {
  #if (req.http.Cache-Control ~ "(?i)no-cache" && client.ip ~ editors) { # create the acl editors if you want to restrict the Ctrl-F5
  # http://varnish.projects.linpro.no/wiki/VCLExampleEnableForceRefresh
  # Ignore requests via proxy caches and badly behaved crawlers
  # like msnbot that send no-cache with every request.
  #  if (! (req.http.Via || req.http.User-Agent ~ "(?i)bot" || req.http.X-Purge)) {
      #set req.hash_always_miss = true; # Doesn't seems to refresh the object in the cache
  #    return(purge); # Couple this with restart in vcl_purge and X-Purge header to avoid loops
  #  }
  #}

  # Large static files are delivered directly to the end-user without
  # waiting for Varnish to fully read the file first.
  # Varnish 4 fully supports Streaming, so set do_stream in vcl_backend_response()
  if (req.url ~ "^[^?]*\.(mp[34]|rar|tar|tgz|gz|wav|zip|bz2|xz|7z|avi|mov|ogm|mpe?g|mk[av]|webm)(\?.*)?$") {
    unset req.http.Cookie;
    return (hash);
  }

  # Remove all cookies for static files
  # A valid discussion could be held on this line: do you really need to cache static files that don't cause load? Only if you have memory left.
  # Sure, there's disk I/O, but chances are your OS will already have these files in their buffers (thus memory).
  # Before you blindly enable this, have a read here: https://ma.ttias.be/stop-caching-static-files/
  if (req.url ~ "^[^?]*\.(bmp|bz2|css|doc|eot|flv|gif|gz|ico|jpeg|jpg|svg|js|less|pdf|png|rtf|swf|txt|woff|woff2|xml)(\?.*)?$") {
    unset req.http.Cookie;
    return (hash);
  }

  if (req.url ~ "^/phpmyadmin/.*$" || req.url ~ "^/phppgadmin/.*$" || req.url ~ "^/server-status.*$") {
    return(synth(403, "For security reasons, this URL is only accessible using localhost (127.0.0.1) as the hostname."));
  }

  # Send Surrogate-Capability headers to announce ESI support to backend
  set req.http.Surrogate-Capability = "key=ESI/1.0";

  if (req.http.Authorization) {
    # Not cacheable by default
    return (pass);
  }

  # Modify (remove) progress.js request parameters.
  if (req.url ~ "^/misc/progress\.js\?[0-9]+$") {
    set req.url = "/misc/progress.js";
  }

  # Modify HTTP X-Forwarded-For header.
  # This will replace Varnish's IP with actual client's.
  unset req.http.X-Forwarded-For;
  set   req.http.X-Forwarded-For = client.ip;

  # Do not cache these paths.
  if (req.url ~ "^/status\.php$" ||
      req.url ~ "^/update\.php$" ||
      req.url ~ "^/ooyala/ping$" ||
      req.url ~ "^/admin" ||
      req.url ~ "^/admin/.*$" ||
      req.url ~ "^/user" ||
      req.url ~ "^/user/.*$" ||
      req.url ~ "^/users/.*$" ||
      req.url ~ "^/info/.*$" ||
      req.url ~ "^/flag/.*$" ||
      req.url ~ "^/batch/.*$" ||
      req.url ~ "^.*/ajax/.*$" ||
      req.url ~ "^.*/ahah/.*$") {
    return (pass);
  }

  # Pipe these paths directly to Apache for streaming.
  if (req.url ~ "^/admin/content/backup_migrate/export") {
    return (pipe);
  }

  # Do not allow outside access to cron.php or install.php.
  if (req.url ~ "^/(cron|install)\.php$" && !client.ip ~ internal) {
    # Have Varnish throw the error directly.
    return(synth(404, "Page not found."));
    # Use a custom error page that you've defined in Drupal at the path "404".
    # set req.url = "/404";
  }

  return (hash);
}

sub vcl_pipe {
  # Called upon entering pipe mode.
  # In this mode, the request is passed on to the backend, and any further data from both the client
  # and backend is passed on unaltered until either end closes the connection. Basically, Varnish will
  # degrade into a simple TCP proxy, shuffling bytes back and forth. For a connection in pipe mode,
  # no other VCL subroutine will ever get called after vcl_pipe.

  # Note that only the first request to the backend will have
  # X-Forwarded-For set.  If you use X-Forwarded-For and want to
  # have it set for all requests, make sure to have:
  # set bereq.http.connection = "close";
  # here.  It is not set by default as it might break some broken web
  # applications, like IIS with NTLM authentication.

  # set bereq.http.Connection = "Close";

  # Implementing websocket support (https://www.varnish-cache.org/docs/4.0/users-guide/vcl-example-websockets.html)
  if (req.http.upgrade) {
    set bereq.http.upgrade = req.http.upgrade;
  }

  return (pipe);
}
 
sub vcl_pass {
  # Called upon entering pass mode. In this mode, the request is passed on to the backend, and the
  # backend's response is passed on to the client, but is not entered into the cache. Subsequent
  # requests submitted over the same client connection are handled normally.

  return (fetch);
}

# The data on which the hashing will take place
sub vcl_hash {
  # Called after vcl_recv to create a hash value for the request. This is used as a key
  # to look up the object in Varnish.

  hash_data(req.url);

  if (req.http.host) {
    hash_data(req.http.host);
  } else {
    hash_data(server.ip);
  }

  # If the client supports compression, keep that in a different cache
  if (req.http.Accept-Encoding) {
    hash_data(req.http.Accept-Encoding);
  }

  # hash cookies for requests that have them
  if (req.http.Cookie) {
    hash_data(req.http.Cookie);
  }

  return (lookup);
}

sub vcl_hit {
  # Called when a cache lookup is successful.

  if (obj.ttl >= 0s) {
    # A pure unadultered hit, deliver it
    return (deliver);
  }

  # https://www.varnish-cache.org/docs/trunk/users-guide/vcl-grace.html
  # When several clients are requesting the same page Varnish will send one request to the backend and place the others on hold while fetching one copy from the backend. In some products this is called request coalescing and Varnish does this automatically.
  # If you are serving thousands of hits per second the queue of waiting requests can get huge. There are two potential problems - one is a thundering herd problem - suddenly releasing a thousand threads to serve content might send the load sky high. Secondly - nobody likes to wait. To deal with this we can instruct Varnish to keep the objects in cache beyond their TTL and to serve the waiting requests somewhat stale content.

  # if (!std.healthy(req.backend_hint) && (obj.ttl + obj.grace > 0s)) {
  #   return (deliver);
  # } else {
  #   return (fetch);
  # }

  # We have no fresh fish. Lets look at the stale ones.
  if (std.healthy(req.backend_hint)) {
    # Backend is healthy. Limit age to 10s.
    if (obj.ttl + 10s > 0s) {
      #set req.http.grace = "normal(limited)";
      return (deliver);
    } else {
      # No candidate for grace. Fetch a fresh object.
      return(fetch);
    }
  } else {
    # backend is sick - use full grace
      if (obj.ttl + obj.grace > 0s) {
      // Object is in grace, deliver it
      // Automatically triggers a background fetch
      // set req.http.grace = "full";
      return (deliver);
    } else {
      # no graced object.
      return (fetch);
    }
  }

  #if (req.method == "PURGE") {
  #  purge;
  #  return (synth(200, "Purged."));
  #}

  # fetch & deliver once we get the result
  return (fetch); # Dead code, keep as a safeguard
}

sub vcl_miss {
  # Called after a cache lookup if the requested document was not found in the cache. Its purpose
  # is to decide whether or not to attempt to retrieve the document from the backend, and which
  # backend to use.

  #if (req.method == "PURGE") {
  #  purge;
  #  return (synth(200, "Purged."));
  #}

  return (fetch);
}
 
# This function is used when a request is sent by our backend (Nginx server)
sub vcl_backend_response {
  # Called after the response headers has been successfully retrieved from the backend.

  # Remove some headers we never want to see
  unset beresp.http.Server;
  unset beresp.http.X-Powered-By;

  # Pause ESI request and remove Surrogate-Control header
  if (beresp.http.Surrogate-Control ~ "ESI/1.0") {
    unset beresp.http.Surrogate-Control;
    set beresp.do_esi = true;
  }

  # Enable cache for all static files
  # The same argument as the static caches from above: monitor your cache size, if you get data nuked out of it, consider giving up the static file cache.
  # Before you blindly enable this, have a read here: https://ma.ttias.be/stop-caching-static-files/
  if (bereq.url ~ "^[^?]*\.(bmp|bz2|css|doc|eot|flv|gif|gz|ico|jpeg|jpg|js|less|mp[34]|pdf|png|rar|rtf|swf|tar|tgz|txt|wav|woff|xml|zip|webm)(\?.*)?$") {
    unset beresp.http.set-cookie;
  }

  # Large static files are delivered directly to the end-user without
  # waiting for Varnish to fully read the file first.
  # Varnish 4 fully supports Streaming, so use streaming here to avoid locking.
  if (bereq.url ~ "^[^?]*\.(mp[34]|rar|tar|tgz|gz|wav|zip|bz2|xz|7z|avi|mov|ogm|mpe?g|mk[av]|webm)(\?.*)?$") {
    unset beresp.http.set-cookie;
    set beresp.do_stream = true;  # Check memory usage it'll grow in fetch_chunksize blocks (128k by default) if the backend doesn't send a Content-Length header, so only enable it for big objects
    set beresp.do_gzip = false;   # Don't try to compress it for storage
  }

  # Sometimes, a 301 or 302 redirect formed via Apache's mod_rewrite can mess with the HTTP port that is being passed along.
  # This often happens with simple rewrite rules in a scenario where Varnish runs on :80 and Apache on :8080 on the same box.
  # A redirect can then often redirect the end-user to a URL on :8080, where it should be :80.
  # This may need finetuning on your setup.
  #
  # To prevent accidental replace, we only filter the 301/302 redirects for now.
  if (beresp.status == 301 || beresp.status == 302) {
    set beresp.http.Location = regsub(beresp.http.Location, ":[0-9]+", "");
  }

  # Set 2min cache if unset for static files
  if (beresp.ttl <= 0s || beresp.http.Set-Cookie || beresp.http.Vary == "*") {
    /*
    * Mark as "Hit-For-Pass" for the next 2 minutes
    */
    set beresp.ttl = 120s; # Important, you shouldn't rely on this, SET YOUR HEADERS in the backend
    set beresp.uncacheable = true;
    return (deliver);
  }

  # Allow stale content, in case the backend goes down.
  # make Varnish keep all objects for 6 hours beyond their TTL
  set beresp.grace = 6h;

	# Only allow cookies to be set if we're in admin area
#	if (beresp.http.Set-Cookie && bereq.url !~ "^/wp-(login|admin)") {
#        	unset beresp.http.Set-Cookie;
#   	}

	# don't cache response to posted requests or those with basic auth
#	if ( bereq.method == "POST" || bereq.http.Authorization ) {
#        	set beresp.uncacheable = true;
#		set beresp.ttl = 120s;
#		return (deliver);
#    	}
 
    	# don't cache search results
#	if ( bereq.url ~ "\?s=" ){
#		set beresp.uncacheable = true;
#                set beresp.ttl = 120s;
#                return (deliver);
#	}
    
	# only cache status ok
#	if ( beresp.status != 200 ) {
#		set beresp.uncacheable = true;
#                set beresp.ttl = 120s;
#                return (deliver);
#	}

	# A TTL of 24h
#	set beresp.ttl = 24h;
	# Define the default grace period to serve cached content
#	set beresp.grace = 30s;
	
  return (deliver);
}
 
# The routine when we deliver the HTTP request to the user
# Last chance to modify headers that are sent to the client
sub vcl_deliver {
  # Called before a cached object is delivered to the client.

  if (obj.hits > 0) { # Add debug header to see if it's a HIT/MISS and the number of hits, disable when not needed
    set resp.http.X-Cache = "HIT";
  } else {
    set resp.http.X-Cache = "MISS";
  }

  # Please note that obj.hits behaviour changed in 4.0, now it counts per objecthead, not per object
  # and obj.hits may not be reset in some cases where bans are in use. See bug 1492 for details.
  # So take hits with a grain of salt
  set resp.http.X-Cache-Hits = obj.hits;

  # Remove some headers: PHP version
  unset resp.http.X-Powered-By;

  # Remove some headers: Apache version & OS
  unset resp.http.Server;
  unset resp.http.X-Drupal-Cache;
  unset resp.http.X-Varnish;
  unset resp.http.Via;
  unset resp.http.Link;
  unset resp.http.X-Generator;

  return (deliver);
}

sub vcl_purge {
  # Only handle actual PURGE HTTP methods, everything else is discarded
  if (req.method != "PURGE") {
    # restart request
    set req.http.X-Purge = "Yes";
    return(restart);
  }

  return (synth(200, "Purged"));
}

sub vcl_synth {
  if (resp.status == 720) {
    # We use this special error status 720 to force redirects with 301 (permanent) redirects
    # To use this, call the following from anywhere in vcl_recv: return (synth(720, "http://host/new.html"));
    set resp.http.Location = resp.reason;
    set resp.status = 301;
    return (deliver);
  } elseif (resp.status == 721) {
    # And we use error status 721 to force redirects with a 302 (temporary) redirect
    # To use this, call the following from anywhere in vcl_recv: return (synth(720, "http://host/new.html"));
    set resp.http.Location = resp.reason;
    set resp.status = 302;
    return (deliver);
  }

  return (deliver);
}

sub vcl_init {
  return (ok);
}
 
sub vcl_fini {
  # Called when VCL is discarded only after all requests have exited the VCL.
  # Typically used to clean up VMODs.

  return (ok);
}
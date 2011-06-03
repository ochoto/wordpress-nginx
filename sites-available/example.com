# -*- mode: nginx; mode: flyspell-prog; mode: autopair; ispell-local-dictionary: "american" -*-

### Nginx configuration for WordPress.

server {
    ## This is to avoid the spurious if for sub-domain name
    ## rewriting. See http://wiki.nginx.org/Pitfalls#Server_Name.
    listen [::]:80;
    server_name www.example.com;
    rewrite ^ $scheme://example.com$request_uri? permanent;
} # server domain rewrite.


server {
    listen [::]:80;
    limit_conn arbeit 10;
    server_name example.com;
    
    ## Parameterization using hostname of access and log filenames.
    access_log /var/log/nginx/example.com_access.log;
    error_log /var/log/nginx/example.com_error.log;

    ## Root and index files.
    root /var/www/sites/wp;
    index index.php index.html;

    ## See the blacklist.conf file at the parent dir: /etc/nginx.
    ## Deny access based on the User-Agent header.
    if ($bad_bot) {
        return 444;
    }
    ## Deny access based on the Referer header.
    if ($bad_referer) {
        return 444;
    }
    
    ## Cache control. Useful for WP super cache.
    add_header Cache-Control "store, must-revalidate, post-check=0, pre-check=0";
    
    ## If no favicon exists return a 204 (no content error).
    location = /favicon.ico {
        try_files $uri =204;
        log_not_found off;
        access_log off;
    }

    ## Don't log robots.txt requests.
    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }
    
    ## Protect the readme.html file to not reveal the installed
    ## version.
    location = /readme.html {
        auth_basic "Restricted Access"; # auth realm                          
        auth_basic_user_file .htpasswd-users; # htpasswd file
    }    
    
    ## Try the requested URI as files before handling it to PHP.
    location / {

        ## Include the WP supercache config.
        include sites-available/wp_supercache.conf;
        
        ## Use PATH_INFO for translating the requests to the
        ## FastCGI. This config follows Igor's suggestion here:
        ## http://forum.nginx.org/read.php?2,124378,124582.
        ## This is preferable to using:
        ## fastcgi_split_path_info ^(.+\.php)(.*)$
        ## It saves one regex in the location. Hence it's faster.

        ## Anything that has an install in its name is restricted.
        location ~ ^(?<script>.+install\.php)(?<path_info>.*)$ {
            auth_basic "Restricted Access"; # auth realm                          
            auth_basic_user_file .htpasswd-users; # htpasswd file
            include fastcgi.conf;
            ## The fastcgi_params must be redefined from the ones
            ## given in fastcgi.conf. No longer standard names
            ## but arbitrary: named patterns in regex.
            fastcgi_param SCRIPT_FILENAME $document_root$script;
            fastcgi_param SCRIPT_NAME $script;
            fastcgi_param PATH_INFO $path_info;
            ## Passing the request upstream to the FastCGI
            ## listener.
            fastcgi_pass phpcgi;
        }

        ## Regular PHP processing.
        location ~ ^(?<script>.+\.php)(?<path_info>.*)$ {
            include fastcgi.conf;
            ## The fastcgi_params must be redefined from the ones
            ## given in fastcgi.conf. No longer standard names
            ## but arbitrary: named patterns in regex.
            fastcgi_param SCRIPT_FILENAME $document_root$script;
            fastcgi_param SCRIPT_NAME $script;
            fastcgi_param PATH_INFO $path_info;
            ## Passing the request upstream to the FastCGI
            ## listener.
            fastcgi_pass phpcgi;
        }

        ## All files/directories that are protected and unaccessible from
        ## the web.
        location ~* ^.*(\.(?:git|svn|htaccess|txt|po[t]*))$ {
            return 404;
        }

        ## Static files are served directly.
        location ~* \.(?:js|css|png|jpg|jpeg|gif|ico)$ {
            expires max;
            log_not_found off;
            ## No need to bleed constant updates. Send the all shebang in one
            ## fell swoop.
            tcp_nodelay off;
        }

        ## Keep a tab on the 'big' static files.
        location ~* ^.+\.(?:m4a|mp[34]|mov|ogg|flv|pdf|ppt[x]*)$ {
            expires 30d;
            ## No need to bleed constant updates. Send the all shebang in one
            ## fell swoop.
            tcp_nodelay off;
        }
    } # / location

    ## The 'final' attempt to serve the request.
    location @nocache {
        try_files $uri $uri/ /index.php?q=$uri&$args;
    }

    ## Including the php-fpm status and ping pages config.
    ## Uncomment to enable if you're running php-fpm.
    #include php_fpm_status.conf;
    
    # # The 404 is signaled through a static page.
    # error_page  404  /404.html;

    # ## All server error pages go to 50x.html at the document root.
    # error_page 500 502 503 504  /50x.html;
    # location = /50x.html {
    # 	root   /var/www/nginx-default;
    # }
} # server

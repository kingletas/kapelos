vcl 4.1;

# Passes every request straight to nginx, so nothing is cached until Magento's own VCL replaces this file.
backend default {
    .host = "web";
    .port = "80";
    .first_byte_timeout = 600s;
}

sub vcl_recv {
    return (pass);
}

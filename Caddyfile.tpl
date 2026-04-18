{{DOMAIN}} {
    tls {{EMAIL}}
    encode gzip
    reverse_proxy frontend:80 {
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }
}

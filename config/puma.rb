# 30 MB upload plus multipart overhead. Puma refuses a larger Content-Length before it spools the body.
http_content_length_limit 32 * 1024 * 1024

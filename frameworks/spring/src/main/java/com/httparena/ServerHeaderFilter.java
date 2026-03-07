package com.httparena;

import jakarta.servlet.*;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;

import java.io.IOException;

@Component
public class ServerHeaderFilter implements Filter {
    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {
        ((HttpServletResponse) response).setHeader("Server", "spring");
        chain.doFilter(request, response);
    }
}

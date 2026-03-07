package com.httparena;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.web.embedded.tomcat.TomcatServletWebServerFactory;
import org.springframework.boot.web.server.Ssl;
import org.springframework.context.annotation.Bean;
import org.apache.catalina.connector.Connector;
import org.apache.coyote.http11.Http11NioProtocol;
import org.apache.tomcat.util.net.SSLHostConfig;
import org.apache.tomcat.util.net.SSLHostConfigCertificate;

import java.io.File;

@SpringBootApplication
public class Application {

    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }

    @Bean
    public TomcatServletWebServerFactory servletContainer() {
        TomcatServletWebServerFactory factory = new TomcatServletWebServerFactory();

        String certPath = System.getenv("TLS_CERT");
        String keyPath = System.getenv("TLS_KEY");
        if (certPath == null) certPath = "/certs/server.crt";
        if (keyPath == null) keyPath = "/certs/server.key";

        if (new File(certPath).exists() && new File(keyPath).exists()) {
            final String cert = certPath;
            final String key = keyPath;
            factory.addAdditionalTomcatConnectors(createH2Connector(cert, key));
        }

        return factory;
    }

    private Connector createH2Connector(String certPath, String keyPath) {
        Connector connector = new Connector("org.apache.coyote.http11.Http11NioProtocol");
        connector.setScheme("https");
        connector.setSecure(true);
        connector.setPort(8443);

        Http11NioProtocol protocol = (Http11NioProtocol) connector.getProtocolHandler();
        protocol.setSSLEnabled(true);

        SSLHostConfig sslHostConfig = new SSLHostConfig();
        SSLHostConfigCertificate certificate = new SSLHostConfigCertificate(sslHostConfig, SSLHostConfigCertificate.Type.RSA);
        certificate.setCertificateFile(certPath);
        certificate.setCertificateKeyFile(keyPath);
        sslHostConfig.addCertificate(certificate);
        sslHostConfig.setProtocols("TLSv1.3");

        connector.addSslHostConfig(sslHostConfig);
        connector.addUpgradeProtocol(new org.apache.coyote.http2.Http2Protocol());

        return connector;
    }
}

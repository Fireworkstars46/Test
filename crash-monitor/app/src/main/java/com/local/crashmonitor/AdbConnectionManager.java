package com.local.crashmonitor;

import android.content.Context;
import android.os.Build;
import android.sun.misc.BASE64Encoder;
import android.sun.security.provider.X509Factory;
import android.sun.security.x509.AlgorithmId;
import android.sun.security.x509.CertificateAlgorithmId;
import android.sun.security.x509.CertificateExtensions;
import android.sun.security.x509.CertificateIssuerName;
import android.sun.security.x509.CertificateSerialNumber;
import android.sun.security.x509.CertificateSubjectName;
import android.sun.security.x509.CertificateValidity;
import android.sun.security.x509.CertificateVersion;
import android.sun.security.x509.CertificateX509Key;
import android.sun.security.x509.KeyIdentifier;
import android.sun.security.x509.PrivateKeyUsageExtension;
import android.sun.security.x509.SubjectKeyIdentifierExtension;
import android.sun.security.x509.X500Name;
import android.sun.security.x509.X509CertImpl;
import android.sun.security.x509.X509CertInfo;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.SecureRandom;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.Date;
import java.util.Random;

import io.github.muntashirakon.adb.AbsAdbConnectionManager;

public class AdbConnectionManager extends AbsAdbConnectionManager {
    private static AdbConnectionManager instance;
    private final PrivateKey privateKey;
    private final Certificate certificate;

    public static synchronized AdbConnectionManager getInstance(Context context) throws Exception {
        if (instance == null) instance = new AdbConnectionManager(context.getApplicationContext());
        return instance;
    }

    private AdbConnectionManager(Context context) throws Exception {
        setApi(Build.VERSION.SDK_INT);
        PrivateKey key = readPrivateKey(context);
        Certificate cert = readCertificate(context);
        if (key == null || cert == null) {
            KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
            generator.initialize(2048, SecureRandom.getInstance("SHA1PRNG"));
            KeyPair pair = generator.generateKeyPair();
            PublicKey publicKey = pair.getPublic();
            key = pair.getPrivate();

            String algorithm = "SHA512withRSA";
            Date notBefore = new Date(System.currentTimeMillis() - 60_000L);
            Date notAfter = new Date(System.currentTimeMillis() + 3650L * 24L * 60L * 60L * 1000L);
            CertificateExtensions extensions = new CertificateExtensions();
            extensions.set("SubjectKeyIdentifier", new SubjectKeyIdentifierExtension(
                    new KeyIdentifier(publicKey).getIdentifier()));
            extensions.set("PrivateKeyUsage", new PrivateKeyUsageExtension(notBefore, notAfter));
            X500Name subject = new X500Name("CN=Crash Monitor");
            X509CertInfo info = new X509CertInfo();
            info.set("version", new CertificateVersion(2));
            info.set("serialNumber", new CertificateSerialNumber(new Random().nextInt() & Integer.MAX_VALUE));
            info.set("algorithmID", new CertificateAlgorithmId(AlgorithmId.get(algorithm)));
            info.set("subject", new CertificateSubjectName(subject));
            info.set("key", new CertificateX509Key(publicKey));
            info.set("validity", new CertificateValidity(notBefore, notAfter));
            info.set("issuer", new CertificateIssuerName(subject));
            info.set("extensions", extensions);
            X509CertImpl generated = new X509CertImpl(info);
            generated.sign(key, algorithm);
            cert = generated;
            writePrivateKey(context, key);
            writeCertificate(context, cert);
        }
        privateKey = key;
        certificate = cert;
    }

    @Override protected PrivateKey getPrivateKey() { return privateKey; }
    @Override protected Certificate getCertificate() { return certificate; }
    @Override protected String getDeviceName() { return "CrashMonitor"; }

    private static PrivateKey readPrivateKey(Context context) {
        File f = new File(context.getFilesDir(), "adb_private.key");
        if (!f.exists()) return null;
        try (InputStream in = new FileInputStream(f)) {
            byte[] bytes = new byte[(int) f.length()];
            int offset = 0;
            while (offset < bytes.length) {
                int n = in.read(bytes, offset, bytes.length - offset);
                if (n < 0) break;
                offset += n;
            }
            return KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(bytes));
        } catch (Exception e) {
            return null;
        }
    }

    private static Certificate readCertificate(Context context) {
        File f = new File(context.getFilesDir(), "adb_cert.pem");
        if (!f.exists()) return null;
        try (InputStream in = new FileInputStream(f)) {
            return CertificateFactory.getInstance("X.509").generateCertificate(in);
        } catch (Exception e) {
            return null;
        }
    }

    private static void writePrivateKey(Context context, PrivateKey key) throws IOException {
        try (OutputStream out = new FileOutputStream(new File(context.getFilesDir(), "adb_private.key"))) {
            out.write(key.getEncoded());
        }
    }

    private static void writeCertificate(Context context, Certificate cert) throws Exception {
        BASE64Encoder encoder = new BASE64Encoder();
        try (OutputStream out = new FileOutputStream(new File(context.getFilesDir(), "adb_cert.pem"))) {
            out.write(X509Factory.BEGIN_CERT.getBytes(StandardCharsets.UTF_8));
            out.write('\n');
            encoder.encode(cert.getEncoded(), out);
            out.write('\n');
            out.write(X509Factory.END_CERT.getBytes(StandardCharsets.UTF_8));
        }
    }
}

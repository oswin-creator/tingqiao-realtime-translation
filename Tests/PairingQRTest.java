import cn.tingqiao.companion.PairingLink;
import com.google.zxing.*;
import com.google.zxing.common.*;
import com.google.zxing.qrcode.QRCodeWriter;
import java.util.*;
public final class PairingQRTest {
    public static void main(String[] args)throws Exception{
        String link="http://192.168.1.2:64121/#0123456789ABCDEF0123456789ABCDEF";
        if(!PairingLink.valid(link))throw new AssertionError("valid pairing link rejected");
        for(String invalid:new String[]{"https://evil.example/", "http://8.8.8.8:80/#0123456789ABCDEF0123456789ABCDEF",link+"?bad",link.replace("192.168.1.2","192.168.1.256"),link.replace("/#","/other#"),link.replace("http://","file://")})if(PairingLink.valid(invalid))throw new AssertionError("unsafe QR accepted");
        BitMatrix qr=new QRCodeWriter().encode(link,BarcodeFormat.QR_CODE,480,480);
        byte[] pixels=new byte[480*480];for(int y=0;y<480;y++)for(int x=0;x<480;x++)pixels[y*480+x]=(byte)(qr.get(x,y)?0:255);
        MultiFormatReader reader=new MultiFormatReader();Map<DecodeHintType,Object> hints=new EnumMap<>(DecodeHintType.class);hints.put(DecodeHintType.POSSIBLE_FORMATS,Collections.singletonList(BarcodeFormat.QR_CODE));reader.setHints(hints);
        String decoded=reader.decodeWithState(new BinaryBitmap(new HybridBinarizer(new PlanarYUVLuminanceSource(pixels,480,480,0,0,480,480,false)))).getText();
        if(!link.equals(decoded) || !PairingLink.valid(decoded))throw new AssertionError("camera Y plane QR decode failed");
        System.out.println("PASS: QR camera decoder and pairing-link validation");
    }
}

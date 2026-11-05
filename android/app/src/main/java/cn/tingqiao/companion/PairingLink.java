package cn.tingqiao.companion;
import java.net.URI;
public final class PairingLink {
    public static boolean valid(String value){
        try{
            URI u=new URI(value);String host=u.getHost();
            if(!"http".equals(u.getScheme()) || host==null || u.getUserInfo()!=null || u.getPort()<1 || u.getPort()>65535 || u.getQuery()!=null || !"/".equals(u.getPath()) || u.getFragment()==null || !u.getFragment().matches("[a-fA-F0-9]{32}"))return false;
            String[] parts=host.split("\\.");if(parts.length!=4)return false;int[] n=new int[4];for(int i=0;i<4;i++){n[i]=Integer.parseInt(parts[i]);if(n[i]<0 || n[i]>255)return false;}
            return n[0]==10 || n[0]==192 && n[1]==168 || n[0]==172 && n[1]>=16 && n[1]<=31;
        }catch(Exception e){return false;}
    }
}

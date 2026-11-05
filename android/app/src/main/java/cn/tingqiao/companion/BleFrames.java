package cn.tingqiao.companion;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

/** Assemble a bounded complete message before decoding UTF-8 (characters may span packets). */
public final class BleFrames {
    public static final int MAX_PAYLOAD = 262144;
    private long message = -1;
    private int total, next;
    private ByteArrayOutputStream buffer = new ByteArrayOutputStream();
    public static final class Complete {
        public final long message; public final String json;
        Complete(long message, String json) { this.message=message;this.json=json; }
    }
    public void reset() { message=-1;next=0;total=0;buffer.reset(); }
    public boolean incomplete() { return message>=0 && next>0 && next<total; }
    public Complete accept(byte[] data) {
        if(data==null || data.length<12 || data[0]!=0x54 || data[1]!=0x51 || data[2]!=1) throw new IllegalArgumentException("invalid frame");
        long id=((long)(data[4]&255)<<24)|((long)(data[5]&255)<<16)|((long)(data[6]&255)<<8)|(data[7]&255);
        int index=((data[8]&255)<<8)|(data[9]&255), count=((data[10]&255)<<8)|(data[11]&255);
        if(count<1 || index>=count || count>32768) throw new IllegalArgumentException("invalid count");
        if(index==0) { reset();message=id;total=count; }
        if(message!=id || total!=count || index!=next) { reset();throw new IllegalArgumentException("missing frame"); }
        if(buffer.size()+data.length-12>MAX_PAYLOAD) { reset();throw new IllegalArgumentException("message too large"); }
        buffer.write(data,12,data.length-12); next++;
        if(next!=total)return null;
        Complete result=new Complete(message,new String(buffer.toByteArray(),StandardCharsets.UTF_8));reset();return result;
    }
}

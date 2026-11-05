import cn.tingqiao.companion.BleFrames;
import java.nio.file.*;
import java.io.*;
public final class BleFramesTest {
 public static void main(String[] args)throws Exception{
  BleFrames decoder=new BleFrames();byte[] fixture=Files.readAllBytes(Paths.get(args[0]));int i=0,count=0;BleFrames.Complete complete=null;byte[] first=null,second=null;
  while(i<fixture.length){int n=((fixture[i]&255)<<8)|(fixture[i+1]&255);i+=2;byte[] frame=java.util.Arrays.copyOfRange(fixture,i,i+n);i+=n;if(first==null)first=frame;else if(second==null)second=frame;BleFrames.Complete value=decoder.accept(frame);count++;if(value!=null)complete=value;}
  if(complete==null || complete.message!=7 || !complete.json.contains("안녕하세요") || !complete.json.contains("中文翻译") || !complete.json.contains("🙂"))throw new AssertionError("cross-language frame roundtrip");
  decoder.accept(first);try{decoder.accept(first.clone());decoder.accept(second);decoder.accept(second);throw new AssertionError("out-of-order accepted");}catch(IllegalArgumentException expected){}
  try{decoder.accept(new byte[12]);throw new AssertionError("invalid header accepted");}catch(IllegalArgumentException expected){}
  System.out.println("PASS: Android reconstructs "+count+" Swift-produced BLE frames; rejects malformed/order errors");
 }
}

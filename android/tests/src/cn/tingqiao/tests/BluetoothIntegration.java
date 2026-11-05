package cn.tingqiao.tests;

import android.app.*;
import android.os.*;
import android.view.accessibility.AccessibilityNodeInfo;
import java.util.*;
import java.io.*;

/** Operates only TingQiao's own UI; system permissions/pairing remain with the user. */
public class BluetoothIntegration extends Instrumentation {
    private String code;
    private UiAutomation ui;
    private void status(String value){Bundle b=new Bundle();b.putString("stage",value);sendStatus(1,b);}
    @Override public void onCreate(Bundle args){code=args.getString("code");start();}
    @Override public void onStart(){
        try{
            if(code==null || !code.matches("[0-9]{6}"))throw new AssertionError("test pairing code required");
            ui=getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
            status("starting_ui_test");
            ParcelFileDescriptor command=ui.executeShellCommand("am start --user 0 -a android.intent.action.MAIN -n cn.tingqiao.companion/.MainActivity");
            try(InputStream in=new ParcelFileDescriptor.AutoCloseInputStream(command)){byte[] b=new byte[1024];while(in.read(b)!=-1){}}
            waitFor("听桥",30000);
            if(has("蓝牙连接 · 无需 Wi-Fi"))click("蓝牙连接 · 无需 Wi-Fi");
            connect(code);
            waitFor("测试字幕 12",120000);
            if(!has("蓝牙已连接"))throw new AssertionError("native BLE connected status missing");
            status("snapshot_received: native test subtitles visible; awaiting Mac clear");
            waitFor("等待下一句对话",120000);
            if(has("测试字幕"))throw new AssertionError("old captions remain after clear");
            status("clear_received: native page empty; awaiting Mac undo");
            waitFor("测试字幕 12",120000);
            status("undo_received: native captions restored; checking wrong code");
            click("更换电脑");connect("000000");
            waitFor("配对码不正确",45000);
            if(has("测试字幕"))throw new AssertionError("captions disclosed with wrong code");
            status("wrong_code_rejected: no subtitles disclosed");
            click("更换电脑");connect(code);
            waitFor("测试字幕 12",60000);
            status("reconnect_received: native subtitles visible again");
            Bundle result=new Bundle();result.putString("result","PASS: BLE native snapshot, clear, undo, wrong-code rejection, reconnect");finish(Activity.RESULT_OK,result);
        }catch(Throwable e){Bundle result=new Bundle();result.putString("result","FAIL: "+e);finish(Activity.RESULT_CANCELED,result);}
    }
    private AccessibilityNodeInfo root(){
        AccessibilityNodeInfo root=ui.getRootInActiveWindow();
        if(root!=null && "cn.tingqiao.companion".contentEquals(root.getPackageName()))return root;
        if(root!=null)root.recycle();return null;
    }
    private boolean has(String text){AccessibilityNodeInfo r=root();if(r==null)return false;try{return !r.findAccessibilityNodeInfosByText(text).isEmpty();}finally{r.recycle();}}
    private void waitFor(String value,long timeout)throws Exception{long until=System.currentTimeMillis()+timeout;while(System.currentTimeMillis()<until){if(has(value))return;Thread.sleep(300);}throw new AssertionError("waiting for own UI: "+value);}
    private void click(String value)throws Exception{
        waitFor(value,30000);AccessibilityNodeInfo r=root();if(r==null)throw new AssertionError("own app not foreground");
        try{for(AccessibilityNodeInfo n:r.findAccessibilityNodeInfosByText(value)){AccessibilityNodeInfo target=n;while(target!=null && !target.isClickable())target=target.getParent();if(target!=null && target.performAction(AccessibilityNodeInfo.ACTION_CLICK))return;}throw new AssertionError("button unavailable: "+value);}finally{r.recycle();}
    }
    private boolean setCode(AccessibilityNodeInfo node,String value){
        if(node==null)return false;
        if("android.widget.EditText".contentEquals(node.getClassName())){Bundle b=new Bundle();b.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,value);return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT,b);}
        for(int i=0;i<node.getChildCount();i++){AccessibilityNodeInfo child=node.getChild(i);try{if(setCode(child,value))return true;}finally{if(child!=null)child.recycle();}}return false;
    }
    private void connect(String value)throws Exception{
        waitFor("六位配对码",30000);AccessibilityNodeInfo r=root();boolean set=false;try{set=setCode(r,value);}finally{if(r!=null)r.recycle();}
        if(!set)throw new AssertionError("pairing code field unavailable");
        if(!has("点击连接"))click("重新扫描附近的听桥");
        waitFor("点击连接",35000);click("点击连接");
    }
}

package cn.tingqiao.companion;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.*;
import android.bluetooth.le.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.os.*;
import java.util.*;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

public final class BleCaptionClient {
    public static final UUID SERVICE=UUID.fromString("C6B20001-6561-4E90-8A5F-54494E475149");
    private static final UUID CONTROL=UUID.fromString("C6B20002-6561-4E90-8A5F-54494E475149"), DATA=UUID.fromString("C6B20003-6561-4E90-8A5F-54494E475149"), CCCD=UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    public interface Listener {
        void status(String text);
        void found(BluetoothDevice device,String name);
        void update(JSONObject update);
        void remember(BluetoothDevice device,JSONObject update);
        default void assistantUnavailable(String id) {}
    }
    private final Activity activity;
    private final Listener listener;
    private final Handler main=new Handler(Looper.getMainLooper());
    private BluetoothAdapter adapter;
    private BluetoothLeScanner scanner;
    private BluetoothGatt gatt;
    private BluetoothDevice selected;
    private BluetoothGattCharacteristic control;
    private ScanCallback scan;
    private final ArrayDeque<byte[]> writes=new ArrayDeque<>();
    private boolean writing=false, authenticated=false, wanted=false, notificationSetup=false, bonding=false, destroyed=false;
    private byte[] currentWrite;
    private String code="", token="", lastStream="";
    private long lastMessage=-1, lastPacketAt=0, lastControlAt=0, writeStartedAt=0, generation=0;
    private int reconnectAttempt=0, discoveryAttempts=0;
    private String phase="连接";
    private final BleFrames frames=new BleFrames();
    private final BroadcastReceiver bondReceiver=new BroadcastReceiver(){public void onReceive(Context c,Intent i){
        if(!BluetoothDevice.ACTION_BOND_STATE_CHANGED.equals(i.getAction()) || selected==null)return;
        BluetoothDevice d=i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
        if(d==null || !selected.getAddress().equals(d.getAddress()))return;
        int state=i.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE,BluetoothDevice.BOND_NONE);
        if(state==BluetoothDevice.BOND_BONDED && bonding){bonding=false;notificationSetup=false;setupNotifications();}
        else if(state==BluetoothDevice.BOND_NONE && bonding){bonding=false;listener.status("系统配对未完成，请重新连接并允许配对。");disconnect();}
    }};
    public BleCaptionClient(Activity activity,Listener listener){
        this.activity=activity;this.listener=listener;
        BluetoothManager m=(BluetoothManager)activity.getSystemService(Context.BLUETOOTH_SERVICE);adapter=m==null?null:m.getAdapter();
        if(Build.VERSION.SDK_INT>=33)activity.registerReceiver(bondReceiver,new IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED),Context.RECEIVER_EXPORTED);
        else activity.registerReceiver(bondReceiver,new IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED));
        main.postDelayed(watchdog,2000);
    }
    public boolean permitted(){
        if(Build.VERSION.SDK_INT>=31)return activity.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN)==PackageManager.PERMISSION_GRANTED && activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)==PackageManager.PERMISSION_GRANTED;
        return activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)==PackageManager.PERMISSION_GRANTED;
    }
    public String[] permissions(){return Build.VERSION.SDK_INT>=31?new String[]{Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.BLUETOOTH_CONNECT}:new String[]{Manifest.permission.ACCESS_FINE_LOCATION};}
    public boolean enabled(){return adapter!=null && permitted() && adapter.isEnabled();}
    public void scan(){
        stopScan();disconnect();
        if(!enabled()){listener.status("请允许附近设备权限，并打开手机蓝牙。");return;}
        scanner=adapter.getBluetoothLeScanner(); if(scanner==null){listener.status("手机暂时无法扫描蓝牙。");return;}
        listener.status("正在寻找附近已开启蓝牙字幕的听桥…");
        scan=new ScanCallback(){
            public void onScanResult(int type,ScanResult result){main.post(()->{if(scan==null)return;String n=result.getScanRecord()==null?null:result.getScanRecord().getDeviceName();listener.found(result.getDevice(),n==null?"听桥 Mac":n);});}
            public void onScanFailed(int code){main.post(()->{listener.status("扫描失败（"+code+"），请稍后重试。");stopScan();});}
        };
        try{scanner.startScan(Collections.singletonList(new ScanFilter.Builder().setServiceUuid(new ParcelUuid(SERVICE)).build()),new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(),scan);}
        catch(SecurityException e){listener.status("请允许附近设备权限。");}
        ScanCallback active=scan;
        main.postDelayed(()->{if(scan==active){stopScan();listener.status("本次扫描已结束；没找到时请确认 Mac 已开启蓝牙字幕，再点重新扫描。");}},20000);
    }
    public void stopScan(){if(scanner!=null && scan!=null)try{scanner.stopScan(scan);}catch(SecurityException ignored){}scan=null;}
    public void connect(BluetoothDevice device,String pairingCode){
        stopScan();disconnect();selected=device;code=pairingCode;token="";wanted=true;reconnectAttempt=0;open();
    }
    public void connectSaved(String address,String savedToken){
        stopScan();disconnect();
        if(!savedToken.matches("[A-Za-z0-9_-]{16}")){listener.status("保存的配对已失效，请忘记设备后重新配对。");return;}
        try{selected=adapter.getRemoteDevice(address);token=savedToken;code="";wanted=true;reconnectAttempt=0;open();}catch(Exception e){listener.status("已保存的电脑暂不可用，请重新扫描。");}
    }
    private void open(){
        if(!wanted || destroyed || !enabled()){if(wanted)retry("蓝牙暂不可用");return;}
        closeGatt();long attempt=++generation;discoveryAttempts=0;phase="连接";
        listener.status(reconnectAttempt==0?"正在连接 Mac…":"连接中断，正在重新连接（"+reconnectAttempt+"）…");
        try{gatt=selected.connectGatt(activity,false,callback,BluetoothDevice.TRANSPORT_LE);}
        catch(Exception e){retry("连接暂时失败");return;}
        main.postDelayed(()->handshakeTimeout(attempt),18000);
    }
    private void handshakeTimeout(long attempt){
        if(!wanted || attempt!=generation || authenticated)return;
        if(selected!=null && selected.getBondState()==BluetoothDevice.BOND_BONDING){main.postDelayed(()->handshakeTimeout(attempt),60000);return;}
        android.util.Log.i("TingQiaoBLE","handshake timeout, bond="+(selected==null?-1:selected.getBondState()));
        retry(phase+"超时");
    }
    private void retry(String reason){
        if(!wanted || destroyed)return;closeGatt();long attempt=++generation;reconnectAttempt++;
        listener.status(reason+"，将自动重连…");
        main.postDelayed(()->{if(wanted && generation==attempt)open();},Math.min(15000,1500*reconnectAttempt));
    }
    public void disconnect(){wanted=false;generation++;stopScan();closeGatt();}
    private void closeGatt(){
        authenticated=false;bonding=false;notificationSetup=false;control=null;writing=false;currentWrite=null;writes.clear();frames.reset();lastStream="";lastMessage=-1;
        BluetoothGatt old=gatt;gatt=null;if(old!=null){try{old.disconnect();old.close();}catch(Exception ignored){}}
    }
    private final BluetoothGattCallback callback=new BluetoothGattCallback(){
        public void onConnectionStateChange(BluetoothGatt g,int status,int state){main.post(()->{
            if(g!=gatt)return;android.util.Log.i("TingQiaoBLE","connection status="+status+" state="+state);
            if(status==BluetoothGatt.GATT_SUCCESS && state==BluetoothProfile.STATE_CONNECTED){phase="读取字幕服务";listener.status("正在读取字幕服务…");main.postDelayed(()->discover(g),500);}
            else if(state==BluetoothProfile.STATE_DISCONNECTED || status!=BluetoothGatt.GATT_SUCCESS)retry("蓝牙已断开（"+status+"）");
        });}
        public void onServicesDiscovered(BluetoothGatt g,int status){main.post(()->{
            if(g!=gatt)return;android.util.Log.i("TingQiaoBLE","services status="+status);if(status!=BluetoothGatt.GATT_SUCCESS){retry("读取服务失败");return;}
            BluetoothGattService service=g.getService(SERVICE);control=service==null?null:service.getCharacteristic(CONTROL);
            if(control==null){listener.status("这台设备没有听桥字幕服务，请更新两端 App。");disconnect();return;}
            // Subscribe at the negotiated/default MTU. Do not race a timed-out MTU
            // operation against a CCCD write; all frames also work at MTU 23.
            phase="订阅字幕";setupNotifications();
        });}
        public void onServiceChanged(BluetoothGatt g){main.post(()->{if(g==gatt)retry("电脑字幕服务已更新");});}
        public void onMtuChanged(BluetoothGatt g,int mtu,int status){main.post(()->{if(g==gatt)setupNotifications();});}
        public void onDescriptorWrite(BluetoothGatt g,BluetoothGattDescriptor descriptor,int status){main.post(()->{
            if(g!=gatt || !CCCD.equals(descriptor.getUuid()))return;android.util.Log.i("TingQiaoBLE","subscription status="+status);
            if(status==BluetoothGatt.GATT_SUCCESS){phase="核对配对码";enqueue(token.isEmpty()?"AUTH:"+code:"KEY:"+token);listener.status("正在核对配对码…");}
            else if(status==5 || status==15)requestBond();else retry("订阅字幕失败（"+status+"）");
        });}
        public void onCharacteristicWrite(BluetoothGatt g,BluetoothGattCharacteristic characteristic,int status){main.post(()->{
            if(g!=gatt || !CONTROL.equals(characteristic.getUuid()))return;
            String command=currentWrite==null?"":new String(currentWrite,StandardCharsets.UTF_8);android.util.Log.i("TingQiaoBLE","control "+command.split(":")[0]+" status="+status);writing=false;currentWrite=null;
            if(status==BluetoothGatt.GATT_SUCCESS){lastControlAt=System.currentTimeMillis();if(command.startsWith("AUTH:") || command.startsWith("KEY:")){authenticated=true;reconnectAttempt=0;listener.status("蓝牙字幕已连接 · 等待新字幕");}nextWrite();}
            else if(command.startsWith("QA:") && command.length()==17){listener.assistantUnavailable(command.substring(5));nextWrite();}
            else if(status==5 || status==15){writes.clear();requestBond();}
            else if(command.startsWith("KEY:")){listener.status("这台电脑已取消配对，请返回忘记设备后重新输入六位码。");disconnect();}
            else if(command.startsWith("AUTH:")){listener.status("配对码不正确或已失效，请返回重新输入 Mac 当前显示的六位码。");disconnect();}
            else retry("蓝牙传输暂时失败");
        });}
        public void onCharacteristicChanged(BluetoothGatt g,BluetoothGattCharacteristic c){byte[] v=c.getValue();if(v!=null){byte[] copy=v.clone();main.post(()->receive(g,c.getUuid(),copy));}}
        public void onCharacteristicChanged(BluetoothGatt g,BluetoothGattCharacteristic c,byte[] value){byte[] copy=value.clone();main.post(()->receive(g,c.getUuid(),copy));}
    };
    private void discover(BluetoothGatt g){
        if(g!=gatt || control!=null)return;
        discoveryAttempts++;
        if(!g.discoverServices()){retry("无法读取蓝牙服务");return;}
        main.postDelayed(()->{if(g==gatt && control==null){if(discoveryAttempts<2)discover(g);else retry("读取字幕服务超时，请确认 Mac 蓝牙字幕已开启");}},6000);
    }
    private void setupNotifications(){
        if(gatt==null || notificationSetup)return;notificationSetup=true;
        BluetoothGattService service=gatt.getService(SERVICE);BluetoothGattCharacteristic c=service==null?null:service.getCharacteristic(DATA);
        BluetoothGattDescriptor d=c==null?null:c.getDescriptor(CCCD);
        if(c==null || d==null || !gatt.setCharacteristicNotification(c,true)){retry("无法订阅蓝牙字幕");return;}
        d.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
        if(!gatt.writeDescriptor(d))retry("订阅字幕暂时失败");
    }
    private void requestBond(){
        if(bonding || selected==null)return;
        if(selected.getBondState()==BluetoothDevice.BOND_BONDED){retry("系统蓝牙配对需要重新确认");return;}
        bonding=true;listener.status("请按手机与 Mac 的系统提示完成蓝牙配对…");
        if(selected.getBondState()!=BluetoothDevice.BOND_BONDING && !selected.createBond()){bonding=false;retry("未能发起系统配对");}
    }
    private void enqueue(String command){if(gatt==null || control==null)return;if(writes.size()>30){retry("蓝牙连接繁忙");return;}writes.add(command.getBytes(StandardCharsets.UTF_8));nextWrite();}
    private void nextWrite(){
        if(writing || writes.isEmpty() || gatt==null || control==null)return;
        currentWrite=writes.remove();control.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);control.setValue(currentWrite);writing=true;writeStartedAt=System.currentTimeMillis();
        if(!gatt.writeCharacteristic(control)){writing=false;retry("蓝牙写入暂时失败");}
    }
    private void receive(BluetoothGatt g,UUID characteristic,byte[] data){
        if(g!=gatt || !DATA.equals(characteristic))return;lastPacketAt=System.currentTimeMillis();
        try{
            BleFrames.Complete result=frames.accept(data);if(result==null)return;
            JSONObject update=new JSONObject(result.json);
            if(update.optInt("version")!=1 || update.getLong("message")!=result.message)throw new IllegalArgumentException();
            String remembered=update.optString("pairingToken","");if(remembered.matches("[A-Za-z0-9_-]{16}")){token=remembered;listener.remember(selected,update);}
            String stream=update.getString("stream");
            if(!stream.equals(lastStream) && !"snapshot".equals(update.getString("kind"))){enqueue("SYNC");return;}
            if(!stream.equals(lastStream) || result.message!=lastMessage){listener.update(update);lastStream=stream;lastMessage=result.message;}
            enqueue("ACK:"+result.message);
        }catch(Exception e){frames.reset();enqueue("SYNC");listener.status("正在补齐蓝牙字幕…");}
    }
    public void resume(){if(wanted && !authenticated && gatt==null)open();else if(authenticated)enqueue("SYNC");}
    public boolean askAssistant(boolean answer, String id){
        if(!authenticated || gatt==null || control==null || !id.matches("[0-9a-f]{12}") || writes.size()>30)return false;
        enqueue("QA:"+(answer?"A:":"E:")+id);
        return true;
    }
    private final Runnable watchdog=new Runnable(){public void run(){
        if(destroyed)return;
        if(wanted && writing && System.currentTimeMillis()-writeStartedAt>12000){retry("蓝牙确认超时");}
        if(authenticated && !writing && writes.isEmpty() && System.currentTimeMillis()-lastControlAt>10000)enqueue("PING");
        if(frames.incomplete() && System.currentTimeMillis()-lastPacketAt>6000){frames.reset();enqueue("SYNC");}
        main.postDelayed(this,2000);
    }};
    public void destroy(){destroyed=true;disconnect();main.removeCallbacksAndMessages(null);try{activity.unregisterReceiver(bondReceiver);}catch(Exception ignored){}}
}

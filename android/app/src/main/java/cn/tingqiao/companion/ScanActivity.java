package cn.tingqiao.companion;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.hardware.Camera;
import android.os.*;
import android.view.*;
import android.widget.*;
import com.google.zxing.*;
import com.google.zxing.common.HybridBinarizer;
import java.util.*;

/** Frames stay on this phone. Only a validated TingQiao LAN link is returned. */
@SuppressWarnings("deprecation")
public final class ScanActivity extends Activity implements SurfaceHolder.Callback {
    private SurfaceView preview;
    private Camera camera;
    private HandlerThread worker;
    private Handler decoder;
    private final Handler main=new Handler(Looper.getMainLooper());
    private boolean resumed=false, surfaceReady=false, done=false;
    private final MultiFormatReader reader=new MultiFormatReader();
    @Override public void onCreate(Bundle state){
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        LinearLayout page=new LinearLayout(this);page.setOrientation(1);page.setPadding(24,48,24,36);page.setBackgroundColor(Color.rgb(246,247,252));
        TextView title=new TextView(this);title.setText("扫描 Mac 上的听桥二维码");title.setTextSize(22);title.setTextColor(Color.rgb(36,43,66));page.addView(title);
        TextView hint=new TextView(this);hint.setText("电脑与手机连接同一个 Wi-Fi。\n画面仅在本机识别，不拍照、不上传。");hint.setPadding(0,18,0,24);page.addView(hint);
        preview=new SurfaceView(this);preview.getHolder().addCallback(this);page.addView(preview,new LinearLayout.LayoutParams(-1,0,1));
        Button cancel=new Button(this);cancel.setText("取消扫码");cancel.setOnClickListener(v->finish());page.addView(cancel);setContentView(page);
        Map<DecodeHintType,Object> hints=new EnumMap<>(DecodeHintType.class);hints.put(DecodeHintType.POSSIBLE_FORMATS,Collections.singletonList(BarcodeFormat.QR_CODE));hints.put(DecodeHintType.TRY_HARDER,true);reader.setHints(hints);
        worker=new HandlerThread("tingqiao-qr");worker.start();decoder=new Handler(worker.getLooper());
        if(checkSelfPermission(Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED)requestPermissions(new String[]{Manifest.permission.CAMERA},51);
    }
    @Override public void onRequestPermissionsResult(int r,String[] p,int[] g){super.onRequestPermissionsResult(r,p,g);if(r==51){if(g.length>0 && g[0]==PackageManager.PERMISSION_GRANTED)startCamera();else{Toast.makeText(this,"相机权限未允许，仍可返回粘贴配对链接。",Toast.LENGTH_LONG).show();finish();}}}
    @Override protected void onResume(){super.onResume();resumed=true;startCamera();}
    @Override protected void onPause(){resumed=false;releaseCamera();super.onPause();}
    @Override protected void onDestroy(){releaseCamera();main.removeCallbacksAndMessages(null);if(worker!=null)worker.quitSafely();super.onDestroy();}
    public void surfaceCreated(SurfaceHolder h){surfaceReady=true;startCamera();}
    public void surfaceChanged(SurfaceHolder h,int f,int w,int he){}
    public void surfaceDestroyed(SurfaceHolder h){surfaceReady=false;releaseCamera();}
    private void startCamera(){
        if(!resumed || !surfaceReady || camera!=null || done || checkSelfPermission(Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED)return;
        try{
            int id=0;Camera.CameraInfo info=new Camera.CameraInfo();for(int i=0;i<Camera.getNumberOfCameras();i++){Camera.getCameraInfo(i,info);if(info.facing==Camera.CameraInfo.CAMERA_FACING_BACK){id=i;break;}}
            Camera.getCameraInfo(id,info);camera=Camera.open(id);Camera.Parameters p=camera.getParameters();
            Camera.Size best=p.getSupportedPreviewSizes().get(0);for(Camera.Size s:p.getSupportedPreviewSizes())if(Math.abs(s.width-640)<Math.abs(best.width-640))best=s;p.setPreviewSize(best.width,best.height);
            List<String> modes=p.getSupportedFocusModes();if(modes!=null && modes.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE))p.setFocusMode(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE);camera.setParameters(p);
            int rotation=getWindowManager().getDefaultDisplay().getRotation()*90;camera.setDisplayOrientation((info.orientation-rotation+360)%360);
            camera.setPreviewDisplay(preview.getHolder());camera.startPreview();nextFrame();
        }catch(Exception e){releaseCamera();Toast.makeText(this,"无法打开相机，请关闭占用相机的软件后重试。",Toast.LENGTH_LONG).show();finish();}
    }
    private void nextFrame(){if(camera!=null && resumed && !done)camera.setOneShotPreviewCallback((data,c)->{
        Camera.Size s=c.getParameters().getPreviewSize();decoder.post(()->decode(data,s.width,s.height));
    });}
    private void decode(byte[] data,int width,int height){
        String value=null;
        try{value=reader.decodeWithState(new BinaryBitmap(new HybridBinarizer(new PlanarYUVLuminanceSource(data,width,height,0,0,width,height,false)))).getText();}catch(Exception ignored){}finally{reader.reset();}
        final String result=value;
        main.post(()->{
            if(!resumed || done)return;
            if(result!=null && PairingLink.valid(result)){done=true;setResult(RESULT_OK,new Intent().putExtra("pairing",result));finish();}
            else{if(result!=null)Toast.makeText(this,"这不是听桥的局域网配对二维码。",Toast.LENGTH_SHORT).show();main.postDelayed(this::nextFrame,300);}
        });
    }
    private void releaseCamera(){if(camera!=null){try{camera.setPreviewCallback(null);camera.stopPreview();}catch(Exception ignored){}camera.release();camera=null;}}
}

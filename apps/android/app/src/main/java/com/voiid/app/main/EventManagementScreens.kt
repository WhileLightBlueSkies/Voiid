package com.voiid.app.main

import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.material3.FilterChip
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.voiid.app.ui.theme.VoiidColor
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.Saver
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.voiid.app.net.*
import com.google.zxing.BarcodeFormat
import com.google.zxing.MultiFormatWriter
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun EventTicketWallet(onDismiss:()->Unit) {
 val ctx=LocalContext.current
 val service=remember { EventService(ApiClient(TokenStore.get(ctx))) }
 var tickets by remember { mutableStateOf<List<EventService.Ticket>?>(null) }
 var selected by remember { mutableStateOf<EventService.Ticket?>(null) }
 var code by remember { mutableStateOf<EventService.TicketCode?>(null) }
 var error by remember { mutableStateOf<String?>(null) }
 var retry by remember { mutableStateOf(0) }
 val lifecycleOwner=LocalLifecycleOwner.current
 LaunchedEffect(retry) {
  error=null
  try { tickets=service.tickets() } catch(e:CancellationException){throw e} catch(_:Exception){error="Unable to load tickets. Please retry."}
 }
 LaunchedEffect(selected?.id,retry,lifecycleOwner) {
  code=null
  val t=selected ?: return@LaunchedEffect
  lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
   try {
    while(true) {
     val fresh=service.ticketCode(t.id)
     code=fresh;error=null
     delay((fresh.expires_at-System.currentTimeMillis()-30_000).coerceIn(1000,570_000))
     code=null
    }
   } catch(e:CancellationException){throw e}
   catch(_:Exception){error="Ticket unavailable. Refresh your ticket and try again."}
   finally{code=null}
  }
 }
 Dialog(onDismissRequest=onDismiss,properties=DialogProperties(usePlatformDefaultWidth=false)) {
  Surface(modifier=Modifier.fillMaxSize(),color=VoiidColor.background) {
   Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
    Row(Modifier.fillMaxWidth().padding(horizontal=12.dp),verticalAlignment=Alignment.CenterVertically) {
     if(selected!=null) TextButton(onClick={selected=null;error=null}){Text("Back")}
     Text(if(selected==null)"My tickets" else "Your ticket",style=MaterialTheme.typography.titleMedium,modifier=Modifier.weight(1f))
     TextButton(onClick=onDismiss){Text("Done")}
    }
    LazyColumn(contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(22.dp)) {
     error?.let { item {Text(it,color=MaterialTheme.colorScheme.error);TextButton(onClick={error=null;retry++}){Text("Refresh ticket")}} }
     val ticket=selected
     if(ticket==null) {
      if(tickets==null&&error==null)item{CircularProgressIndicator()}
      if(tickets?.isEmpty()==true)item{Text("No tickets yet.")}
      tickets?.forEach { t->item {
       val usable=t.state=="valid"&&t.order_status=="paid"&&t.event_status=="published"&&t.checked_in_at==null
       Card(onClick={error=null;selected=t},enabled=usable,modifier=Modifier.fillMaxWidth(),shape=RoundedCornerShape(22.dp)) {
        Column(Modifier.padding(20.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
         Text(t.title ?: "Event",style=MaterialTheme.typography.titleLarge)
         Text("${t.people} ${if(t.people==1)"person" else "people"} · ${t.statusLine()}")
        }
       }
      } }
     } else {
      item {
       Text("Event ticket",style=MaterialTheme.typography.labelLarge,color=VoiidColor.accentInk)
       Spacer(Modifier.height(12.dp))
       Text(ticket.title ?: "Event",style=MaterialTheme.typography.headlineLarge)
       ticket.starts_at?.let{Text(runCatching{java.time.Instant.parse(it).atZone(java.time.ZoneId.systemDefault()).format(java.time.format.DateTimeFormatter.ofPattern("EEE, d MMM · h:mm a"))}.getOrDefault(it),modifier=Modifier.padding(top=12.dp))}
       ticket.location_text?.let{Text(it,modifier=Modifier.padding(top=8.dp))}
      }
      item {
       Surface(shape=RoundedCornerShape(28.dp),color=VoiidColor.surfaceCard) {
        Column(Modifier.fillMaxWidth().padding(22.dp),verticalArrangement=Arrangement.spacedBy(20.dp),horizontalAlignment=Alignment.CenterHorizontally) {
         Column(Modifier.fillMaxWidth()) {
          Text("GROUP ENTRY",style=MaterialTheme.typography.labelSmall)
          Text("Admits ${ticket.people} ${if(ticket.people==1)"person" else "people"}",style=MaterialTheme.typography.headlineSmall)
         }
         HorizontalDivider()
         val currentCode=code
         if(currentCode!=null && currentCode.expires_at>System.currentTimeMillis()) {
          val bitmap=remember(currentCode.code) {
           val matrix=MultiFormatWriter().encode(currentCode.code,BarcodeFormat.QR_CODE,720,720)
           android.graphics.Bitmap.createBitmap(720,720,android.graphics.Bitmap.Config.ARGB_8888).apply {
            val pixels=IntArray(720*720){n->if(matrix[n%720,n/720])android.graphics.Color.BLACK else android.graphics.Color.WHITE}
            setPixels(pixels,0,720,0,0,720,720)
           }
          }
          Image(bitmap.asImageBitmap(),"Admission QR for ${ticket.people} people",modifier=Modifier.widthIn(max=300.dp).fillMaxWidth().background(Color.White,RoundedCornerShape(20.dp)).padding(16.dp).aspectRatio(1f))
          Text("One QR. Your whole group.",style=MaterialTheme.typography.titleMedium)
          Text("Arrive together. Scan once to check everyone in.",style=MaterialTheme.typography.bodyMedium)
         } else if(error==null) CircularProgressIndicator()
        }
       }
      }
     }
    }
   }
  }
 }
}

@Composable
fun EventManagerDialog(event:EventService.Event,canManage:Boolean,canAssign:Boolean=false,onDismiss:()->Unit,onChanged:()->Unit){
 val ctx=LocalContext.current
 val service=remember{EventService(ApiClient(TokenStore.get(ctx)))}
 val scope=rememberCoroutineScope()
 var orders by remember{mutableStateOf<List<EventService.HostOrder>?>(null)}
 var error by remember{mutableStateOf<String?>(null)}
 var busy by remember{mutableStateOf(false)}
 var code by remember{mutableStateOf("")}
 var result by remember{mutableStateOf<String?>(null)}
 var cancel by remember{mutableStateOf(false)}
 var showTeam by remember{mutableStateOf(false)}
 var showScanner by remember{mutableStateOf(false)}
 var editing by remember{mutableStateOf(false)}
 var tab by remember{mutableStateOf("Overview")}
 var search by remember{mutableStateOf("")}
 var refundTarget by remember{mutableStateOf<EventService.HostOrder?>(null)}
 var notice by remember{mutableStateOf<String?>(null)}
 if(editing) { EventEditorDialog(communityId="",event=event,onDismiss={editing=false},onSaved={onChanged();onDismiss()}); return }
 if(showScanner) { EventAdmissionScanner(event,onDismiss={showScanner=false},onAdmitted={ _ -> onChanged()}); return }
 if(showTeam) { EventTeamDialog(event.id) { showTeam=false }; return }
 var retry by remember{mutableStateOf(0)}
 LaunchedEffect(event.id,retry,canManage){
  error=null
  if(canManage)try{orders=service.orders(event.id)}catch(e:CancellationException){throw e}catch(_:Exception){orders=null;error="Unable to load registrations. Check your access and connection."}
 }
 fun transition(action:String){scope.launch{busy=true;error=null;try{service.transition(event.id,action);onChanged();onDismiss()}catch(e:CancellationException){throw e}catch(_:Exception){error="Unable to update event. Refresh and try again."}finally{busy=false}}}

 EventControlPage("Event workspace",{if(!busy)onDismiss()}) {
  LazyColumn(contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(24.dp)) {
   item{Text(event.status?.replaceFirstChar{it.uppercase()} ?: "Event",style=MaterialTheme.typography.labelLarge);Text(event.title,style=MaterialTheme.typography.headlineLarge);event.location_text?.let{Text(it)}}
   if(event.status=="published")item{Button(onClick={showScanner=true},modifier=Modifier.fillMaxWidth().heightIn(min=54.dp)){Text("Open check-in desk")}}
   if(canManage) {
    orders?.let{list->item{Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){ControlMetric("Registered",list.filter{it.status=="paid"}.sumOf{it.quantity},Modifier.weight(1f));ControlMetric("Checked in",list.sumOf{it.checked_in},Modifier.weight(1f))}}}
    item{Text("Counts cover up to 500 bookings.",style=MaterialTheme.typography.bodySmall)}
    item{Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){listOf("Overview","Guests","Check-in").forEach{label->FilterChip(selected=tab==label,onClick={tab=label},label={Text(label)})}}}
   }
   error?.let{item{Text(it);TextButton(onClick={retry++}){Text("Refresh")}}}
   notice?.let{item{Text(it,color=VoiidColor.accentInk)}}
   if(canManage&&tab=="Overview") {
    item{Surface(shape=RoundedCornerShape(24.dp),color=VoiidColor.surfaceCard){Column(Modifier.fillMaxWidth().padding(22.dp),verticalArrangement=Arrangement.spacedBy(16.dp)){
     Text("Event details",style=MaterialTheme.typography.titleLarge)
     event.description?.let{Text(it)}
     event.starts_at?.let{Text(runCatching{java.time.Instant.parse(it).atZone(java.time.ZoneId.systemDefault()).format(java.time.format.DateTimeFormatter.ofPattern("EEE, d MMM · h:mm a"))}.getOrDefault(it))}
     Text(event.capacity?.let{"$it places"} ?: "Unlimited capacity")
    }}}
    if(event.status!="cancelled")item{ControlEntry("Edit event","Details, schedule and capacity"){editing=true}}
    if(canAssign)item{ControlEntry("Event team","Managers and check-in volunteers"){showTeam=true}}
    if(event.status=="draft")item{Button(enabled=!busy,onClick={transition("publish")}){Text("Publish event")}}
    if(event.status!="cancelled")item{TextButton(enabled=!busy,onClick={cancel=true}){Text("Cancel event",color=MaterialTheme.colorScheme.error)}}
   }
   if(canManage&&tab=="Guests") {
    item{OutlinedTextField(search,{search=it},label={Text("Search guest or username")},modifier=Modifier.fillMaxWidth());Text("Showing up to 500 bookings. Phone numbers are not shared.",style=MaterialTheme.typography.bodySmall)}
    if(orders==null&&error==null)item{CircularProgressIndicator()}
    if(orders?.isEmpty()==true)item{Text("No registrations yet.")}
    orders?.filter{search.isBlank()||it.full_name.orEmpty().contains(search,true)||it.username.orEmpty().contains(search,true)}?.forEach{o->item{
     Surface(shape=RoundedCornerShape(20.dp),color=VoiidColor.surfaceCard){Row(Modifier.fillMaxWidth().padding(20.dp),verticalAlignment=Alignment.CenterVertically){
      Column(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(6.dp)){Text(o.display,style=MaterialTheme.typography.titleMedium);Text(orderDetail(o),style=MaterialTheme.typography.bodySmall,
       color=if(o.refund_error!=null)VoiidColor.error else VoiidColor.textSecondary)}
      if(o.canRefund)TextButton(enabled=!busy,onClick={refundTarget=o},modifier=Modifier.semantics{contentDescription="Refund ${o.display}"}){Text(if(o.refund_error==null)"Refund" else "Retry",color=VoiidColor.error)}
     }}
    }}
   }
   if(event.status=="published"&&(!canManage||tab=="Check-in"))item{
    Text("One scan admits the whole booking",style=MaterialTheme.typography.titleLarge)
    Text("Ask the whole group to arrive together. Used bookings cannot be admitted again.")
    Spacer(Modifier.height(20.dp))
    OutlinedTextField(value=code,onValueChange={code=it;result=null},label={Text("Enter ticket code manually")},enabled=!busy,modifier=Modifier.fillMaxWidth())
    TextButton(enabled=!busy&&code.isNotBlank(),onClick={scope.launch{busy=true;result=null;try{val r=service.checkIn(event.id,code.trim());result=if(r.ok)"${r.people} ${if(r.people==1)"person" else "people"} admitted" else "Not admitted";code="";retry++}catch(e:CancellationException){throw e}catch(e:Exception){result=admissionError(e)}finally{busy=false}}}){Text(if(busy)"Checking…" else "Check in")}
    result?.let{Text(it)}
   }
  }
 }

 // iOS EventHostView: with paid orders, cancelling offers "refund everyone" as an explicit choice.
 val paidCount=orders.orEmpty().count{it.status=="paid"&&(it.amount_minor?:0)>0}
 if(cancel)com.voiid.app.ui.components.VoiidDialogCustom(onDismissRequest={if(!busy)cancel=false},backDismissable=!busy,scrimDismissable=!busy){
  Text("Cancel this event?",style=MaterialTheme.typography.titleMedium)
  Text(if(paidCount>0)"Cancelling stops registration and admission. $paidCount ${if(paidCount==1)"person has" else "people have"} paid — refunding everyone returns their full amount to how they paid, usually within 5–7 working days. This cannot be reversed."
   else "Cancelling stops admission. Refunds are handled separately.",style=MaterialTheme.typography.bodyMedium,color=VoiidColor.textSecondary)
  if(paidCount>0)com.voiid.app.ui.components.VoiidDialogAction("Cancel and refund everyone",destructive=true,enabled=!busy){scope.launch{busy=true;error=null
   try{val(req,failed)=service.cancelAndRefund(event.id);cancel=false
    notice=if(failed==0)"Cancelled. $req refund${if(req==1)"" else "s"} on the way." else "Cancelled. $req refund${if(req==1)"" else "s"} on the way, $failed failed — retry them from the attendee list.";onChanged();retry++}
   catch(e:CancellationException){throw e}catch(_:Exception){error="Unable to update event. Refresh and try again."}finally{busy=false}}}
  com.voiid.app.ui.components.VoiidDialogAction(if(paidCount>0)"Cancel without refunds" else "Cancel event",destructive=true,enabled=!busy){transition("cancel")}
  com.voiid.app.ui.components.VoiidDialogAction("Keep it",enabled=!busy){cancel=false}
 }
 refundTarget?.let{o->com.voiid.app.ui.components.VoiidDialogCustom(onDismissRequest={refundTarget=null}){
  Text("Refund ${o.amount_minor?.let{java.text.NumberFormat.getCurrencyInstance().apply{currency=java.util.Currency.getInstance(o.currency?:"INR")}.format(it/100.0)} ?: ""} to ${o.display}?",style=MaterialTheme.typography.titleMedium)
  listOf("attendee_request" to "Requested by the attendee","event_changed" to "Event changed","duplicate_payment" to "Duplicate payment","event_cancelled" to "Event cancelled").forEach{(code,label)->
   com.voiid.app.ui.components.VoiidDialogAction(label){refundTarget=null;scope.launch{busy=true;error=null
    try{service.refundOrder(event.id,o.id,code);notice="Refund on the way to ${o.display}."}catch(e:CancellationException){throw e}catch(e:Exception){error=e.message?:"Refund failed."}finally{busy=false;retry++}}}}
  com.voiid.app.ui.components.VoiidDialogAction("Don't refund"){refundTarget=null}
 }}
}


@Composable
fun EventStaffInvitations(communityId:String,onChanged:()->Unit) {
 val ctx=LocalContext.current;val service=remember{EventService(ApiClient(TokenStore.get(ctx)))};val scope=rememberCoroutineScope()
 var invites by remember(communityId){mutableStateOf<List<EventService.StaffInvite>>(emptyList())}
 var error by remember(communityId){mutableStateOf<String?>(null)}
 var retry by remember{mutableStateOf(0)};var busy by remember{mutableStateOf(false)}
 LaunchedEffect(communityId,retry){try{invites=service.invitations(communityId);error=null}catch(e:CancellationException){throw e}catch(_:Exception){error="Unable to load staff invitations."}}
 error?.let{Text(it);TextButton(onClick={retry++}){Text("Retry invitations")}}
 invites.filter{it.state=="pending"}.forEach { invite->
  Column {
   Text("Staff invitation: ${invite.title}")
   Text(if(invite.role=="volunteer")"Check-in access for this event only." else "Event editing, registrations and check-in. No banking access.")
   TextButton(enabled=!busy,onClick={scope.launch{busy=true;try{service.acceptInvite(invite.event_id);retry++;onChanged()}catch(e:CancellationException){throw e}catch(_:Exception){error="Unable to accept invitation. Check membership and expiry."}finally{busy=false}}}){Text("Accept invitation")}
  }
 }
}

@Composable
private fun EventTeamDialog(id:String,onDismiss:()->Unit){
 val ctx=LocalContext.current;val service=remember{EventService(ApiClient(TokenStore.get(ctx)))};val scope=rememberCoroutineScope()
 var team by remember{mutableStateOf<List<EventService.StaffMember>>(emptyList())}
 var username by remember{mutableStateOf("")};var role by remember{mutableStateOf("volunteer")}
 var error by remember{mutableStateOf<String?>(null)};var busy by remember{mutableStateOf(false)}
 var retry by remember{mutableStateOf(0)}
 LaunchedEffect(id,retry){try{team=service.team(id);error=null}catch(e:CancellationException){throw e}catch(_:Exception){team=emptyList();error="Unable to load team. Check your access."}}
 fun action(block:suspend()->Unit){scope.launch{busy=true;try{block();retry++}catch(e:CancellationException){throw e}catch(_:Exception){error="Unable to update team."}finally{busy=false}}}
 AlertDialog(onDismissRequest={if(!busy)onDismiss()},title={Text("Event team")},text={LazyColumn(verticalArrangement=Arrangement.spacedBy(12.dp)){
  item{
   OutlinedTextField(value=username,onValueChange={username=it},label={Text("Member username")},enabled=!busy)
   Row {TextButton(enabled=!busy,onClick={role="volunteer"}){Text(if(role=="volunteer")"✓ Volunteer" else "Volunteer")};TextButton(enabled=!busy,onClick={role="manager"}){Text(if(role=="manager")"✓ Manager" else "Manager")}}
   Text(if(role=="volunteer")"Can check in guests for this event only." else "Can edit this event and view registrations. No bank access.")
   TextButton(enabled=!busy&&username.isNotBlank(),onClick={action{service.invite(id,username.trim(),role);username=""}}){Text("Send invitation")}
  }
  error?.let{item{Text(it);TextButton(onClick={retry++}){Text("Retry")}}}
  team.forEach{m->item{Text(m.full_name ?: m.username ?: "Member");Text("${m.role} · ${m.state} · ends ${m.expires_at}");if(m.state!="revoked")TextButton(enabled=!busy,onClick={action{service.removeStaff(id,m.user_id)}}){Text("Remove access")}}}
 }},confirmButton={TextButton(enabled=!busy,onClick=onDismiss){Text("Done")}})
}

@Composable
fun EventGroupBooking(event:EventService.Event,onDismiss:()->Unit,onBooked:()->Unit) {
 val ctx=LocalContext.current
 val service=remember{EventService(ApiClient(TokenStore.get(ctx)))}
 val scope=rememberCoroutineScope()
 var quantity by remember{mutableStateOf(1)}
 var busy by remember{mutableStateOf(false)}
 var error by remember{mutableStateOf<String?>(null)}
 val checkoutLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
  androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()
 ) { result ->
  scope.launch {
   busy=true
   try {
    var paid=false
    repeat(if(result.resultCode==android.app.Activity.RESULT_OK)12 else 1) {
     if(!paid) {
      paid=service.orderStatus(event.id)=="paid"
      if(!paid && result.resultCode==android.app.Activity.RESULT_OK) kotlinx.coroutines.delay(1000)
     }
    }
    if(paid)onBooked() else error="Payment not yet confirmed. Check My tickets before paying again."
   } catch(e:CancellationException){throw e}
   catch(_:Exception){error="Unable to confirm payment. Check My tickets before paying again."}
   finally{busy=false}
  }
 }
 val maximum=(event.capacity ?: 10).coerceIn(1,10)
 Dialog(onDismissRequest={if(!busy)onDismiss()},properties=DialogProperties(usePlatformDefaultWidth=false)) {
  Surface(Modifier.fillMaxSize(),color=VoiidColor.background) {
   LazyColumn(contentPadding=PaddingValues(20.dp),modifier=Modifier.statusBarsPadding().navigationBarsPadding(),verticalArrangement=Arrangement.spacedBy(24.dp)) {
    item{Row(verticalAlignment=Alignment.CenterVertically){Text("Book tickets",Modifier.weight(1f),style=MaterialTheme.typography.titleMedium);TextButton(enabled=!busy,onClick=onDismiss){Text("Close")}}}
    item{Text(event.title,style=MaterialTheme.typography.headlineLarge);event.location_text?.let{Text(it)}}
    item{
     Surface(shape=RoundedCornerShape(24.dp),color=VoiidColor.surfaceCard) {
      Column(Modifier.padding(22.dp),verticalArrangement=Arrangement.spacedBy(20.dp)) {
       Text("How many people?",style=MaterialTheme.typography.headlineSmall)
       Row(verticalAlignment=Alignment.CenterVertically) {
        Text("$quantity ${if(quantity==1)"person" else "people"}",Modifier.weight(1f),style=MaterialTheme.typography.titleLarge)
        OutlinedButton(enabled=!busy&&quantity>1,onClick={quantity--}){Text("−")}
        Spacer(Modifier.width(8.dp))
        OutlinedButton(enabled=!busy&&quantity<maximum,onClick={quantity++}){Text("+")}
       }
       HorizontalDivider()
       Text("One QR for your whole booking",style=MaterialTheme.typography.titleMedium)
       Text("Arrive together. Scanning once checks in everyone in this booking.")
      }
     }
    }
    item{Row{Text("Total",Modifier.weight(1f));Text(if(event.free)"Free" else String.format(java.util.Locale.ROOT,"%s %.2f",event.currency ?: "INR",(event.price_minor ?: 0)*quantity/100.0),style=MaterialTheme.typography.headlineSmall)}}
    error?.let{item{Text(it,color=MaterialTheme.colorScheme.error)}}
    item{Button(enabled=!busy,onClick={scope.launch{
     busy=true;error=null
     try{
      val response=org.json.JSONObject(service.rsvp(event.id,quantity))
      val order=response.getJSONObject("order")
      if(order.getString("status")=="paid")onBooked()
      else {
       val checkout=response.optJSONObject("checkout") ?: error("Checkout unavailable")
       checkoutLauncher.launch(android.content.Intent(ctx,com.voiid.app.payments.EventCheckoutActivity::class.java)
        .putExtra("checkout",checkout.toString()))
      }
     }
     catch(e:CancellationException){throw e}
     catch(_:Exception){error="Unable to reserve places. Refresh the event and try again."}
     finally{busy=false}
    }},modifier=Modifier.fillMaxWidth().heightIn(min=52.dp)){Text(if(busy)"Please wait…" else if(event.free)"Reserve $quantity ${if(quantity==1)"place" else "places"}" else "Continue to payment")}}
   }
  }
 }
}

@Composable
private fun EventAdmissionScanner(event:EventService.Event,onDismiss:()->Unit,onAdmitted:(Int)->Unit) {
 val ctx=LocalContext.current
 val haptics=com.voiid.app.ui.components.LocalVoiidHaptics.current
 val service=remember{EventService(ApiClient(TokenStore.get(ctx)))}
 val scope=rememberCoroutineScope()
 val lifecycleOwner=LocalLifecycleOwner.current
 var active by remember{mutableStateOf(false)}
 var allowed by remember{mutableStateOf(androidx.core.content.ContextCompat.checkSelfPermission(ctx,android.Manifest.permission.CAMERA)==android.content.pm.PackageManager.PERMISSION_GRANTED)}
 val permission=androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.RequestPermission()){allowed=it}
 var cameraError by remember{mutableStateOf(false)}
 var busy by remember{mutableStateOf(false)}
 var latched by remember{mutableStateOf(false)}
 var admitted by remember{mutableStateOf(false)}
 var result by remember{mutableStateOf<String?>(null)}
 var people by remember{mutableStateOf(0)}
 LaunchedEffect(Unit){if(!allowed)permission.launch(android.Manifest.permission.CAMERA)}
 LaunchedEffect(lifecycleOwner){lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED){active=true;try{kotlinx.coroutines.awaitCancellation()}finally{active=false}}}
 Dialog(onDismissRequest={if(!busy)onDismiss()},properties=DialogProperties(usePlatformDefaultWidth=false)) {
  Surface(Modifier.fillMaxSize(),color=VoiidColor.background) {
   Column(Modifier.statusBarsPadding().navigationBarsPadding().padding(20.dp),verticalArrangement=Arrangement.spacedBy(20.dp)) {
    Row(verticalAlignment=Alignment.CenterVertically){Text("Check-in desk",Modifier.weight(1f),style=MaterialTheme.typography.headlineSmall);TextButton(enabled=!busy,onClick=onDismiss){Text("Done")}}
    Text(event.title,style=MaterialTheme.typography.titleLarge)
    if(allowed&&!cameraError) Box(Modifier.fillMaxWidth().weight(1f)) {
     CameraFeed(scanning=active&&!busy&&!latched,onCamera={},onError={cameraError=true},onDecoded={value->
      if(!busy&&!latched){
       latched=true;busy=true;result=null;admitted=false
       scope.launch {
        try {
         val response=service.checkIn(event.id,value)
         admitted=response.ok
         if(response.ok){haptics.success();people+=response.people;result="${response.people} ${if(response.people==1)"person" else "people"} admitted";onAdmitted(response.people)}
         else {haptics.error();result="Not admitted. Check the booking before trying again."}
        } catch(e:CancellationException){throw e}
        catch(e:Exception){haptics.error();result=admissionError(e)}
        finally{busy=false}
       }
      }
     })
    } else Text("Camera unavailable. Enable camera access in Settings, or return to enter a ticket code.")
    if(busy)CircularProgressIndicator()
    result?.let {
     Surface(color=if(admitted)MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.errorContainer,shape=RoundedCornerShape(24.dp)) {
      Text(it,modifier=Modifier.fillMaxWidth().padding(24.dp),style=MaterialTheme.typography.headlineSmall)
     }
    }
    if(latched)Button(enabled=!busy,onClick={latched=false;result=null;admitted=false},modifier=Modifier.fillMaxWidth().heightIn(min=52.dp)){Text("Scan next booking")}
    Text("$people people checked in on this device",style=MaterialTheme.typography.bodySmall)
   }
  }
 }
}

private fun admissionError(error:Exception):String = when((error as? ApiError.Http)?.message) {
 "already_checked_in" -> "Already checked in. Do not admit this booking again."
 "expired", "superseded", "group_code_required", "group_unavailable" -> "Ask the guest to refresh their group ticket, then scan again."
 "wrong_event" -> "This ticket is for a different event."
 "void", "unpaid" -> "This booking is not valid for admission."
 "access_removed" -> "Your check-in access is no longer active."
 "event_unavailable" -> "This event is not open for check-in."
 "malformed", "bad_signature", "not_found" -> "This is not a valid Voiid ticket."
 else -> "Could not verify. Check your connection before trying again."
}

@Composable
internal fun EventControlPage(title:String,onDismiss:()->Unit,closeLabel:String="Done",content:@Composable ColumnScope.()->Unit) {
 Dialog(onDismissRequest=onDismiss,properties=DialogProperties(usePlatformDefaultWidth=false)) {
  Surface(Modifier.fillMaxSize(),color=VoiidColor.background) {
   Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
    Row(Modifier.fillMaxWidth().padding(horizontal=16.dp),verticalAlignment=Alignment.CenterVertically) {
     Text(title,Modifier.weight(1f),style=MaterialTheme.typography.titleMedium)
     TextButton(onClick=onDismiss){Text(closeLabel)}
    }
    content()
   }
  }
 }
}

@Composable
fun CommunityControlPanel(card:CommunityService.CommunityCard,isOwner:Boolean,onDismiss:()->Unit,onSettings:()->Unit) {
 val ctx=LocalContext.current
 val community=remember{CommunityService(ctx)}
 val eventsService=remember{EventService(ApiClient(TokenStore.get(ctx)))}
 var stats by remember{mutableStateOf<CommunityService.Stats?>(null)}
 var events by remember{mutableStateOf<List<EventService.Event>>(emptyList())}
 var error by remember{mutableStateOf<String?>(null)}
 var retry by remember{mutableStateOf(0)}
 var destination by remember{mutableStateOf<String?>(null)}
 // iOS CommunityAdminPanel sections: Overview · Queue · People.
 var section by remember{mutableStateOf("Overview")}
 var queue by remember{mutableStateOf<List<CommunityService.QueueItem>>(emptyList())}
 var queueError by remember{mutableStateOf<String?>(null)}
 var busy by remember{mutableStateOf(setOf<String>())}
 val scope=rememberCoroutineScope()
 LaunchedEffect(card.id,retry,section){
  if(section=="Queue") try{queue=community.moderationQueue(card.id);queueError=null}
  catch(e:CancellationException){throw e}catch(_:Exception){queueError="Couldn't load the queue."}
 }
 LaunchedEffect(card.id,retry){
  try {val s=community.stats(card.id);val e=eventsService.list(card.id);stats=s;events=e;error=null}
  catch(e:CancellationException){throw e}catch(_:Exception){stats=null;error="Unable to load the community overview. Check your access and connection."}
 }
 val kycService=remember{KycService(ctx)}
 var kyc by remember{mutableStateOf<KycService.Verification?>(null)}
 LaunchedEffect(destination){ if(isOwner&&destination==null) kyc=runCatching{kycService.me()}.getOrNull() }
 if(destination=="People")CommunityPeoplePanel(card,isOwner){destination=null;retry++}
 if(destination=="CreateEvent"){EventEditorDialog(communityId=card.id,isOwner=isOwner,onDismiss={destination=null},onSaved={destination=null;retry++});return}
 if(destination=="Verify"){HostVerificationScreen{destination=null};return}
 if(destination=="Invite")CommunityInviteSheet(card,community){destination=null}
 if(destination=="Earnings")CommunityEarningsDialog(card.id){destination=null}
 if(destination=="Events")EventControlPage("Events",{destination=null}) {
  LazyColumn(contentPadding=PaddingValues(20.dp)){item{CommunityEventsSection(card.id,isOwner=isOwner,isManager=true,managementContext=true)}}
 }
 if(destination=="Insights")EventControlPage("Insights",{destination=null}) {
  LazyColumn(contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(24.dp)) {
   item{Text("Community at a glance",style=MaterialTheme.typography.headlineLarge);Text("Current totals")}
   stats?.let{s->item{Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){ControlMetric("Members",s.memberCount,Modifier.weight(1f));ControlMetric("Posts",s.postCount,Modifier.weight(1f))}}}
   item{Surface(shape=RoundedCornerShape(24.dp),color=VoiidColor.surfaceCard){Column(Modifier.fillMaxWidth().padding(22.dp),verticalArrangement=Arrangement.spacedBy(16.dp)){
    Text("Events",style=MaterialTheme.typography.titleLarge)
    listOf("published","draft","cancelled").forEach{status->Row{Text(status.replaceFirstChar{it.uppercase()},Modifier.weight(1f));Text(events.count{it.status==status}.toString())}}
   }}}
   item{Text("Discovery views and referral analytics are not available yet.",style=MaterialTheme.typography.bodySmall)}
  }
 }
 if(destination!=null&&destination!="Invite")return
 // ONE SCREEN A HOST CAN READ IN A GLANCE, top to bottom by urgency — what is waiting on them,
 // the four things they do most, the one step that unlocks money (owners, until done), the
 // numbers, then everything else. Mirrors iOS CommunityAdminPanel.
 EventControlPage("Admin panel",onDismiss) {
  LazyColumn(contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) {
   item{Text(card.name,style=MaterialTheme.typography.headlineLarge)}
   item{Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){listOf("Overview","Queue","People").forEach{label->
    FilterChip(selected=section==label,onClick={ if(label=="People") destination="People" else section=label },label={Text(label)})}}}
   if(section=="Queue"){
    queueError?.let{item{Text(it,color=VoiidColor.error);TextButton(onClick={retry++}){Text("Retry")}}}
    if(queueError==null&&queue.isEmpty())item{Surface(shape=RoundedCornerShape(22.dp),color=VoiidColor.surfaceCard){
     Text("Nothing needs you right now.",Modifier.fillMaxWidth().padding(18.dp),color=VoiidColor.textSecondary)}}
    queue.forEach{q->item(key=q.id){Surface(shape=RoundedCornerShape(22.dp),color=VoiidColor.surfaceCard){
     Column(Modifier.fillMaxWidth().padding(18.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){
      Row{Text(q.name,style=MaterialTheme.typography.titleSmall,modifier=Modifier.weight(1f))
       q.reporter_count?.takeIf{it>1}?.let{Text("$it reports",color=VoiidColor.warning,style=MaterialTheme.typography.labelMedium)}}
      (q.detail?:q.reason)?.takeIf{it.isNotBlank()}?.let{Text(it,color=VoiidColor.textSecondary,style=MaterialTheme.typography.bodyMedium)}
      val uid=q.user_id
      if(q.resolvedKind==CommunityService.QueueItem.Kind.JOIN_REQUEST&&uid!=null)Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){
       listOf(true,false).forEach{approve->TextButton(enabled=q.id !in busy,onClick={scope.launch{
        busy=busy+q.id
        try{if(approve)community.approveMember(card.id,uid) else community.removeMember(card.id,uid);queue=queue.filterNot{it.id==q.id};retry++}
        catch(e:CancellationException){throw e}catch(_:Exception){queueError="Couldn't complete that."}
        busy=busy-q.id}}){Text(if(approve)"Approve" else "Decline",color=if(approve)VoiidColor.accentInk else VoiidColor.error)}}
      }
     }}}}
   } else {
   error?.let{item{Text(it);TextButton(onClick={retry++}){Text("Retry")}}}
   stats?.let{s->
    val waiting=s.pendingCount+s.openReports
    item{
     if(waiting>0) Card(onClick={section="Queue"},modifier=Modifier.fillMaxWidth(),shape=RoundedCornerShape(22.dp),
      colors=CardDefaults.cardColors(containerColor=VoiidColor.surfaceCard),border=androidx.compose.foundation.BorderStroke(1.dp,VoiidColor.warning.copy(alpha=0.45f))){
      Row(Modifier.padding(18.dp),verticalAlignment=Alignment.CenterVertically){
       Column(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(4.dp)){
        Text("Needs you",style=MaterialTheme.typography.titleMedium)
        Text(listOfNotNull(if(s.pendingCount>0)"${s.pendingCount} join request${if(s.pendingCount==1)"" else "s"}" else null,
         if(s.openReports>0)"${s.openReports} report${if(s.openReports==1)"" else "s"}" else null).joinToString(" · "),style=MaterialTheme.typography.bodySmall)
       }
       Text("Review",color=VoiidColor.accentInk,style=MaterialTheme.typography.titleSmall)
      }
     } else Surface(shape=RoundedCornerShape(22.dp),color=VoiidColor.surfaceCard){
      Text("All caught up — no requests or reports waiting.",Modifier.fillMaxWidth().padding(18.dp),color=VoiidColor.textSecondary)
     }
    }
   } ?: if(error==null)item{CircularProgressIndicator()} else Unit
   item{Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){
    QuickAction("Create event",Modifier.weight(1f)){destination="CreateEvent"}
    QuickAction("Invite people",Modifier.weight(1f)){destination="Invite"}
   }}
   item{Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){
    QuickAction("Review queue",Modifier.weight(1f)){section="Queue"}
    QuickAction("Settings",Modifier.weight(1f),onSettings)
   }}
   // Every unverified owner sees it, even before payments are switched on — the screen says so.
   kyc?.let{k-> if(isOwner&&!k.isVerified) item{
    ControlEntry(if(k.isInReview)"Verification in review" else "Get verified to sell tickets",
     if(k.isInReview)"Voiid is checking your details. Paid events unlock when it's approved." else "Verify your PAN and bank account once to charge for events."){destination="Verify"}
   }}
   stats?.let{s->item{Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){ControlMetric("Members",s.memberCount,Modifier.weight(1f));ControlMetric("Posts",s.postCount,Modifier.weight(1f))}}}
   item{Text("MORE",style=MaterialTheme.typography.labelMedium,color=VoiidColor.textSecondary)}
   item{ControlEntry("Events","Manage events and check in guests"){destination="Events"}}
   item{ControlEntry("Insights","Community activity and event status"){destination="Insights"}}
   if(isOwner)item{ControlEntry("Earnings","Sales, commission and your share"){destination="Earnings"}}
   }
  }
 }
}

@Composable
private fun QuickAction(title:String,modifier:Modifier=Modifier,onClick:()->Unit) {
 Card(onClick=onClick,modifier=modifier.heightIn(min=84.dp),shape=RoundedCornerShape(22.dp),colors=CardDefaults.cardColors(containerColor=VoiidColor.surfaceCard)) {
  Box(Modifier.fillMaxWidth().padding(18.dp),contentAlignment=Alignment.BottomStart){Text(title,style=MaterialTheme.typography.titleSmall)}
 }
}

@Composable
private fun ControlMetric(title:String,value:Int,modifier:Modifier=Modifier) {
 Surface(modifier,shape=RoundedCornerShape(24.dp),color=VoiidColor.surfaceCard) {
  Column(Modifier.padding(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){Text(title,style=MaterialTheme.typography.bodyMedium);Text(value.toString(),style=MaterialTheme.typography.headlineLarge)}
 }
}
@Composable
private fun ControlEntry(title:String,detail:String,onClick:()->Unit) {
 Card(onClick=onClick,modifier=Modifier.fillMaxWidth(),shape=RoundedCornerShape(22.dp),colors=CardDefaults.cardColors(containerColor=VoiidColor.surfaceCard)) {
  Row(Modifier.padding(20.dp),verticalAlignment=Alignment.CenterVertically){Column(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(5.dp)){Text(title,style=MaterialTheme.typography.titleMedium);Text(detail,style=MaterialTheme.typography.bodySmall)};Text("›",style=MaterialTheme.typography.titleLarge)}
 }
}

@Composable
/**
 * PAID TICKETS NEED A VERIFIED OWNER. A price is accepted only when the community's owner has
 * passed host verification (routes/kyc.ts), because ticket money is paid out to their bank
 * account. So Tickets reads the caller's verification: an owner who isn't verified gets a
 * "Get verified" door instead of a price field that could only fail. Mirrors iOS
 * `EventCreateFlow`. The price is set at creation; editing never changes it.
 */
fun EventEditorDialog(communityId:String,event:EventService.Event?=null,isOwner:Boolean=false,onDismiss:()->Unit,onSaved:()->Unit) {
 val ctx=LocalContext.current
 val service=remember{EventService(ApiClient(TokenStore.get(ctx)))}
 val scope=rememberCoroutineScope()
 var step by rememberSaveable{mutableStateOf(0)}
 var title by rememberSaveable{mutableStateOf(event?.title ?: "")}
 var about by rememberSaveable{mutableStateOf(event?.description ?: "")}
 val initial=remember{event?.starts_at?.let{runCatching{java.time.Instant.parse(it).atZone(java.time.ZoneId.systemDefault()).toLocalDateTime()}.getOrNull()} ?: java.time.LocalDateTime.now().plusDays(1).withHour(19).withMinute(0).withSecond(0).withNano(0)}
 var date by rememberSaveable(stateSaver=Saver<java.time.LocalDate,String>(save={it.toString()},restore={java.time.LocalDate.parse(it)})){mutableStateOf(initial.toLocalDate())}
 var time by rememberSaveable(stateSaver=Saver<java.time.LocalTime,String>(save={it.toString()},restore={java.time.LocalTime.parse(it)})){mutableStateOf(initial.toLocalTime())}
 val initialEnd=remember{event?.ends_at?.let{runCatching{java.time.Instant.parse(it).atZone(java.time.ZoneId.systemDefault()).toLocalDateTime()}.getOrNull()} ?: initial.plusHours(2)}
 var hasEnd by rememberSaveable{mutableStateOf(event?.ends_at!=null)}
 var endDate by rememberSaveable(stateSaver=Saver<java.time.LocalDate,String>(save={it.toString()},restore={java.time.LocalDate.parse(it)})){mutableStateOf(initialEnd.toLocalDate())}
 var endTime by rememberSaveable(stateSaver=Saver<java.time.LocalTime,String>(save={it.toString()},restore={java.time.LocalTime.parse(it)})){mutableStateOf(initialEnd.toLocalTime())}
 var venue by rememberSaveable{mutableStateOf(event?.location_text ?: "")}
 var capacity by rememberSaveable{mutableStateOf(event?.capacity?.toString() ?: "")}
 var publish by rememberSaveable{mutableStateOf(false)}
 var paid by rememberSaveable{mutableStateOf(false)}
 var priceText by rememberSaveable{mutableStateOf("")}
 // Paise, or null. ₹1 is Cashfree's minimum order.
 val priceMinor=priceText.toBigDecimalOrNull()?.takeIf{it>=java.math.BigDecimal.ONE&&it<=java.math.BigDecimal(100000)}
  ?.multiply(java.math.BigDecimal(100))?.setScale(0,java.math.RoundingMode.HALF_UP)?.toInt()
 val kycService=remember{com.voiid.app.net.KycService(ctx)}
 var kyc by remember{mutableStateOf<com.voiid.app.net.KycService.Verification?>(null)}
 var showVerify by remember{mutableStateOf(false)}
 LaunchedEffect(showVerify){ if(!showVerify) kyc=runCatching{kycService.me()}.getOrNull() }
 val canCharge=isOwner&&kyc?.isVerified==true
 var busy by remember{mutableStateOf(false)}
 var error by remember{mutableStateOf<String?>(null)}
 val capacityValid=capacity.isEmpty() || (capacity.toIntOrNull()?.let{it in 1..100000}==true)
 val startFuture=event!=null || java.time.LocalDateTime.of(date,time).isAfter(java.time.LocalDateTime.now())
 val timesValid=startFuture && (!hasEnd||java.time.LocalDateTime.of(endDate,endTime).isAfter(java.time.LocalDateTime.of(date,time)))
 val valid=when(step){0->title.trim().length in 1..120;1->timesValid;2->capacityValid&&(!paid||priceMinor!=null);else->timesValid&&capacityValid&&title.isNotBlank()}
 val focus=LocalFocusManager.current
 val listState=rememberLazyListState()
 var confirmClose by remember{mutableStateOf(false)}
 LaunchedEffect(step){ focus.clearFocus(); listState.scrollToItem(0); error=null }
 fun changeStart(newDate:java.time.LocalDate,newTime:java.time.LocalTime) {
  date=newDate;time=newTime
  val start=java.time.LocalDateTime.of(date,time)
  if(!java.time.LocalDateTime.of(endDate,endTime).isAfter(start)) {
   val end=start.plusHours(2);endDate=end.toLocalDate();endTime=end.toLocalTime()
  }
 }
 if(showVerify){ HostVerificationScreen{showVerify=false}; return }
 if(confirmClose) AlertDialog(onDismissRequest={confirmClose=false},title={Text("Discard event changes?")},
  text={Text("Your changes haven’t been saved.")},
  confirmButton={TextButton(onClick={confirmClose=false;onDismiss()}){Text("Discard")}},
  dismissButton={TextButton(onClick={confirmClose=false}){Text("Keep editing")}})
 EventControlPage(if(event==null)"Create event" else "Edit event",{if(!busy)confirmClose=true},closeLabel="Close") {

  LazyColumn(state=listState,contentPadding=PaddingValues(20.dp),modifier=Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(24.dp)) {
   item{LinearProgressIndicator(progress={ (step+1)/4f },modifier=Modifier.fillMaxWidth());Spacer(Modifier.height(12.dp));Text("Step ${step+1} of 4 · ${listOf("Details","Schedule","Tickets","Review")[step]}")}
   item{
    Text(listOf("What's happening?","When is it?","Your venue and tickets",if(event==null)"Ready to create?" else "Ready to save?")[step],style=MaterialTheme.typography.headlineLarge)
    // iOS EventCreateFlow step subtitles.
    Text(listOf("A name and a line about it. You can edit both later.","A start time is required. An end time is optional.",
     "Set your venue and the number of places available.","Check the details before making your event available.")[step],
     color=VoiidColor.textSecondary,modifier=Modifier.padding(top=6.dp))
   }
   when(step) {
    0->item{OutlinedTextField(title,{title=it.take(120)},singleLine=true,supportingText={Text("${title.length}/120")},label={Text("Event name")},modifier=Modifier.fillMaxWidth(),enabled=!busy);Spacer(Modifier.height(16.dp));OutlinedTextField(about,{about=it.take(5000)},label={Text("About this event")},modifier=Modifier.fillMaxWidth(),minLines=3,enabled=!busy)}
    1->item{
     ControlEntry("Date",date.format(java.time.format.DateTimeFormatter.ofPattern("EEE, d MMM yyyy"))){android.app.DatePickerDialog(ctx,{_,y,m,d->changeStart(java.time.LocalDate.of(y,m+1,d),time)},date.year,date.monthValue-1,date.dayOfMonth).show()}
     Spacer(Modifier.height(16.dp))
     ControlEntry("Time",time.format(java.time.format.DateTimeFormatter.ofPattern("h:mm a"))){android.app.TimePickerDialog(ctx,{_,h,m->changeStart(date,java.time.LocalTime.of(h,m))},time.hour,time.minute,android.text.format.DateFormat.is24HourFormat(ctx)).show()}
     Row(verticalAlignment=Alignment.CenterVertically){Text("Set an end time",Modifier.weight(1f));Switch(hasEnd,{hasEnd=it})}
     if(hasEnd){
      ControlEntry("End date",endDate.toString()){android.app.DatePickerDialog(ctx,{_,y,m,d->endDate=java.time.LocalDate.of(y,m+1,d)},endDate.year,endDate.monthValue-1,endDate.dayOfMonth).show()}
      Spacer(Modifier.height(16.dp))
      ControlEntry("End time",endTime.format(java.time.format.DateTimeFormatter.ofPattern("h:mm a"))){android.app.TimePickerDialog(ctx,{_,h,m->endTime=java.time.LocalTime.of(h,m)},endTime.hour,endTime.minute,android.text.format.DateFormat.is24HourFormat(ctx)).show()}
     }
     if(!timesValid)Text(if(!startFuture)"Choose a start time in the future." else "End time must be after the start.",color=MaterialTheme.colorScheme.error)
     Text("Time zone: ${java.time.ZoneId.systemDefault().id}",style=MaterialTheme.typography.bodySmall)
    }
    2->item{
     OutlinedTextField(venue,{venue=it.take(300)},label={Text("Venue")},modifier=Modifier.fillMaxWidth(),enabled=!busy)
     Spacer(Modifier.height(16.dp))
     OutlinedTextField(capacity,{capacity=it.filter(Char::isDigit).take(6)},singleLine=true,keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Number),supportingText={Text(if(capacityValid)"Leave empty for unlimited places" else "Enter between 1 and 100,000")},label={Text("Guest capacity")},isError=!capacityValid,modifier=Modifier.fillMaxWidth(),enabled=!busy)
     Spacer(Modifier.height(20.dp))
     if(event==null){
      Row(verticalAlignment=Alignment.CenterVertically){Text("Charge for tickets",Modifier.weight(1f),style=MaterialTheme.typography.titleMedium);Switch(paid,{paid=it},enabled=!busy)}
      if(paid){
       when{
        canCharge->OutlinedTextField(priceText,{priceText=it.filter{c->c.isDigit()||c=='.'}.take(9)},singleLine=true,prefix={Text("₹")},
         keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Decimal),label={Text("Price per place")},
         isError=priceText.isNotEmpty()&&priceMinor==null,supportingText={Text(if(priceText.isNotEmpty()&&priceMinor==null)"Enter a price from ₹1 to ₹1,00,000." else "Paid through Cashfree. Voiid's fee comes off each sale and your share goes to your verified bank account.")},
         modifier=Modifier.fillMaxWidth(),enabled=!busy)
        isOwner->ControlEntry(if(kyc?.isInReview==true)"Verification in review" else "Get verified to sell tickets",
         if(kyc?.isInReview==true)"You can set a price once Voiid approves it." else "About two minutes. PAN and a bank account."){showVerify=true}
        else->Text("Only the community owner can sell tickets, after they verify their identity.",color=VoiidColor.textSecondary)
       }
      } else Text("Free entry. Guests choose up to 10 places; one QR admits their whole booking.",color=VoiidColor.textSecondary)
     } else {Text(if(event.free)"Free entry" else "Paid event",style=MaterialTheme.typography.titleLarge);Text("The price can't change once the event exists.",style=MaterialTheme.typography.bodySmall,color=VoiidColor.textSecondary)}
     if(event==null)Row(verticalAlignment=Alignment.CenterVertically){Text("Publish immediately",Modifier.weight(1f));Switch(publish,{publish=it})}
    }
    else->item{
     Surface(shape=RoundedCornerShape(24.dp),color=VoiidColor.surfaceCard){Column(Modifier.fillMaxWidth().padding(22.dp),verticalArrangement=Arrangement.spacedBy(16.dp)){
      Text(title,style=MaterialTheme.typography.titleLarge);Text("$date · ${time.format(java.time.format.DateTimeFormatter.ofPattern("h:mm a"))}")
      Text(venue.ifBlank{"Venue not specified"});Text(if(capacity.isBlank())"Unlimited capacity" else "$capacity places")
      val priceLine=if(paid&&priceMinor!=null)"₹"+java.math.BigDecimal(priceMinor).movePointLeft(2).stripTrailingZeros().toPlainString()+" per place" else "Free entry"
      Text(if(event==null&&publish)"Publish now · $priceLine" else if(event==null)"Save as draft · $priceLine" else "Save changes")
     }}
    }
   }
   error?.let{item{Text(it,color=MaterialTheme.colorScheme.error)}}
  }
  Row(Modifier.imePadding().padding(20.dp),horizontalArrangement=Arrangement.spacedBy(12.dp)) {
   if(step>0)OutlinedButton(enabled=!busy,onClick={step--},modifier=Modifier.weight(1f)){Text("Back")}
   Button(enabled=valid&&!busy,onClick={
    if(step<3)step++ else {
     busy=true;error=null
     scope.launch{
     try{
      val start=java.time.LocalDateTime.of(date,time).atZone(java.time.ZoneId.systemDefault()).toInstant().toString()
      val end=if(hasEnd)java.time.LocalDateTime.of(endDate,endTime).atZone(java.time.ZoneId.systemDefault()).toInstant().toString() else null
      val draft=EventService.EventDraft(title.trim(),about.trim(),start,end,venue.trim(),capacity.toIntOrNull(),
       price_minor=if(event==null&&paid)(priceMinor ?: 0) else 0,publish=publish)
      if(event==null)service.create(communityId,draft) else service.edit(event.id,draft)
      onSaved()
     }catch(e:CancellationException){throw e}catch(e:Exception){
      error=if((e as? ApiError.Http)?.code=="kyc_required")"The community owner needs to be verified before this event can charge for tickets."
       else "Unable to save. Check the event details, your access and connection."
     }finally{busy=false}
    }}
   },modifier=Modifier.weight(1f)){Text(if(busy)"Saving…" else if(step==3) { if(event!=null) "Save changes" else if(publish) "Publish event" else "Save draft" } else "Continue")}
  }
 }
}

@Composable
private fun CommunityPeoplePanel(card:CommunityService.CommunityCard,isOwner:Boolean,onDismiss:()->Unit) {
 val ctx=LocalContext.current;val service=remember{CommunityService(ctx)};val scope=rememberCoroutineScope()
 val myId=remember{TokenStore.get(ctx).userId}
 var state by remember{mutableStateOf("active")}
 var people by remember{mutableStateOf<List<CommunityService.Member>>(emptyList())}
 var error by remember{mutableStateOf<String?>(null)}
 var loading by remember{mutableStateOf(true)}
 var busy by remember{mutableStateOf(false)}
 var more by remember{mutableStateOf(false)}
 var retry by remember{mutableStateOf(0)}
 var confirm by remember{mutableStateOf<Pair<CommunityService.Member,String>?>(null)}
 suspend fun load(append:Boolean=false) {
  loading=true;error=null
  try{val page=service.members(card.id,state,if(append)people.size else 0);people=if(append)people+page else page;more=page.size==50}
  catch(e:CancellationException){throw e}catch(_:Exception){error="Unable to load members. Check access and connection."}
  finally{loading=false}
 }
 LaunchedEffect(state,retry){people=emptyList();load()}
 fun act(member:CommunityService.Member,action:String){scope.launch{
  busy=true;error=null
  try{when(action){"approve"->service.approveMember(card.id,member.user_id);"ban"->service.banMember(card.id,member.user_id);"unban"->service.unbanMember(card.id,member.user_id);"admin","member"->service.setRole(card.id,member.user_id,action)};confirm=null;retry++}
  catch(e:CancellationException){throw e}catch(_:Exception){confirm=null;error="Unable to update access. Refresh and try again."}
  finally{busy=false}
 }}
 EventControlPage("People and access",{if(!busy)onDismiss()}) {
  LazyColumn(contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(20.dp)) {
   item{Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){listOf("active" to "Members","pending" to "Requests","banned" to "Blocked").forEach{(value,label)->FilterChip(selected=state==value,onClick={if(!busy)state=value},label={Text(label)})}}}
   error?.let{item{Text(it,color=MaterialTheme.colorScheme.error);TextButton(onClick={retry++}){Text("Retry")}}}
   people.forEach{m->item{
    Surface(shape=RoundedCornerShape(22.dp),color=VoiidColor.surfaceCard){Column(Modifier.fillMaxWidth().padding(20.dp),verticalArrangement=Arrangement.spacedBy(10.dp)) {
     Text(m.full_name ?: m.username?.let{"@$it"} ?: "Member",style=MaterialTheme.typography.titleMedium)
     Text(m.role ?: "member",style=MaterialTheme.typography.bodySmall)
     if(m.user_id!=myId && !m.isOwner && m.user_id!=card.owner_id) {
      if(state=="pending")Button(enabled=!busy,onClick={act(m,"approve")}){Text("Approve")}
      if(state=="active"&&isOwner)TextButton(enabled=!busy,onClick={confirm=m to if(m.role=="admin")"member" else "admin"}){Text(if(m.role=="admin")"Remove admin access" else "Make community admin")}
      TextButton(enabled=!busy,onClick={confirm=m to if(state=="banned")"unban" else "ban"}){Text(if(state=="banned")"Unblock" else "Block from community")}
     }
    }}
   }}
   if(loading)item{CircularProgressIndicator()}
   if(!loading&&people.isEmpty()&&error==null)item{Text("No people in this list.")}
   if(more&&!loading)item{TextButton(onClick={scope.launch{load(true)}}){Text("Load more")}}
  }
 }
 confirm?.let{(member,action)->AlertDialog(onDismissRequest={if(!busy)confirm=null},title={Text(if(action=="admin")"Grant community admin access?" else "Update this member's access?")},text={Text(if(action=="admin")"They can manage the community and its events. Event-only managers should be invited from the event team screen." else if(action=="ban")"They will be removed and cannot rejoin until unblocked." else "This changes their access to this community.")},confirmButton={TextButton(enabled=!busy,onClick={act(member,action)}){Text("Confirm")}},dismissButton={TextButton(enabled=!busy,onClick={confirm=null}){Text("Cancel")}})}
}


/** Twin of iOS EventHostView.orderDetail — the attendee's state in words. */
private fun orderDetail(o:EventService.HostOrder):String {
 val parts=mutableListOf<String>()
 if(o.quantity>1)parts+="${o.quantity} tickets"
 if(o.checked_in>0)parts+="Checked in"
 if(o.status=="paid"&&o.refund_error!=null){parts+="Refund failed: ${o.refund_error}";return parts.joinToString(" · ")}
 if(o.status=="paid"&&o.refund_requested_at!=null){parts+="Refund on the way";o.refund_reason?.let{parts+=it};return parts.joinToString(" · ")}
 parts+=when(o.status){"paid"->"Confirmed";"pending"->"Holding a seat";"cancelled"->"Cancelled";"refunded"->"Refunded";"failed"->"Payment failed";else->o.status}
 return parts.joinToString(" · ")
}

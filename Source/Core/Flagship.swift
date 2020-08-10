//
//  ABFlagShip.swift
//  Flagship
//
//  Created by Adel on 02/08/2019.
//

import Foundation


/**
 
 `FlagShip` class helps you run FlagShip on your native iOS app.
 
 */

public class Flagship:NSObject{
    
    /// This id is unique for the app
    internal(set) public var visitorId:String!
    
    /// Customer id
   // internal var fsProfile:FSProfile!
    
    /// Client Id
    internal var environmentId:String!
    
    
    // fsQueue
    let fsQueue = DispatchQueue(label: "com.flagship.queue", attributes: .concurrent)
    
    
    /// Current Context
    internal var context:FSContext!
    
    
    /// All Campaigns
    private var _campaigns:FSCampaigns!
    
    internal var campaigns:FSCampaigns!{
        
        get {
            return fsQueue.sync {
                
                _campaigns
            }
        }
        set {
            fsQueue.async(flags: .barrier) {
                
                self._campaigns = newValue
            }
        }
    }
    
    
    
    /// Service
    private var _service:ABService?
    
    internal var service:ABService?{
        
        get {
            return fsQueue.sync {
                
                _service
            }
        }
        set {
            fsQueue.async(flags: .barrier) {
                
                self._service = newValue
            }
        }
    }
    
    
    /// Enable Logs, By default is equal to True
    @objc public var enableLogs:Bool = true
    
    
    /// Panic Button let you disable the SDK if needed
    private var _disabledSdk:Bool = false
    
    
    @objc public var disabledSdk:Bool{
        
        get {
            return fsQueue.sync {
                
                _disabledSdk
            }
        }
        set {
            fsQueue.async(flags: .barrier) {
                
                self._disabledSdk = newValue
            }
        }
    }
    
    
    
    
    internal var sdkModeRunning:FlagshipMode = .DECISION_API  // By default 
    
    
    /// Shared instance
    @objc public static let sharedInstance:Flagship = {
        
        let instance = Flagship()
        // setup code
        return instance
    }()
    
    
    /// Audience
    let audience:FSAudience!
    
    
    internal override init() {
        // init context
        self.context = FSContext()
        
        self.audience = FSAudience()
        
    }
    
    
    /**
     Start FlagShip
     
     @param envId String environmentId id for client
     
     @param apiKey String provided by abtasty apiKey
     
     @param visitorId String visitor id @optional
     
     @param FSConfig Object config @optional
     
     @param onStartDone The block to be invoked when sdk is ready
     */
    @objc public  func start( envId:String,  apiKey:String, visitorId:String?, config:FSConfig = FSConfig(), onStartDone:@escaping(FlagshipResult)->Void){
        
        // Checkc the environmentId
        if (FSTools.chekcXidEnvironment(envId)){
            
            self.environmentId = envId
            
        }else{
            
            onStartDone(.NotReady)
            return
        }
        
        /// Manage visitor id
        do {
            self.visitorId =  try FSTools.manageVisitorId(visitorId)
            
        }catch{
            
            onStartDone(.NotReady)
            FSLogger.FSlog(String(format: "The visitor id is empty. The SDK Flagship is not ready "), .Campaign)
            return
        }
        
        // Get All Campaign for the moment
        self.service = ABService(self.environmentId, self.visitorId ?? "", apiKey, timeoutService:config.flagshipTimeOutRequestApi)
        
        
        // Set the préconfigured Context
        self.context.currentContext.merge(FSPresetContext.getPresetContextForApp()) { (_, new) in new }
        
        
        // Add the keys all_users temporary
        self.context.currentContext.updateValue("", forKey:ALL_USERS)
        
        
        // The current context is
        FSLogger.FSlog("The current context is : \(self.context.currentContext.description)", .Campaign)
        
        sdkModeRunning = config.mode
        
        switch sdkModeRunning {
            
        case .BUCKETING:
            onSatrtBucketing(onStartDone)
            break
            
        case .DECISION_API:
            onStartDecisionApi(onStartDone)
            break
        }
        
        
        
        /// Send the keys/values context
        DispatchQueue(label: "flagship.contextKey.queue").async {
            
            self.service?.sendkeyValueContext(self.context.currentContext)
        }
        
        // Purge data event
        DispatchQueue(label: "flagShip.FlushStoredEvents.queue").async(execute:DispatchWorkItem {
            self.service?.threadSafeOffline.flushStoredEvents()
        })
        
    }
    
    /**
     getCampaigns
     
     @param pBlock The block to be invoked when sdk receive campaign
     */
    internal func getCampaigns(onGetCampaign:@escaping(FlagshipError?)->Void){
        
        if disabledSdk{
            FSLogger.FSlog("The Sdk is disabled", .Campaign)
            return
        }
        
        FSLogger.FSlog("Get Campaign .............", .Campaign)
        
        if self.service != nil {
            
            self.service?.getCampaigns(context.currentContext) { (campaigns, error) in
                
                if (error == nil){
                    
                    // Check if the sdk is disabled
                    if let panic = campaigns?.panic {
                        
                        if(panic){
                            
                            self.disabledSdk = true
                            
                            FSLogger.FSlog(String(format: "The FlagShip is disabled from the front"), .Campaign)
                            
                            FSLogger.FSlog(String(format: "Default values will be set by the SDK"), .Campaign)
                            
                        }else{
                            
                            self.disabledSdk = false
                            // Set Campaigns
                            self.campaigns = campaigns
                            self.context.updateModification(campaigns)
                            FSLogger.FSlog(String(format: "The get Campaign are %@", campaigns.debugDescription), .Campaign)
                            
                        }
                    }
                    /// Return wihtout error
                    onGetCampaign(.None)
                }else{
                    
                    FSLogger.FSlog(String(format: "Error on get campaign", campaigns.debugDescription), .Campaign)
                    
                    onGetCampaign(.GetCampaignError)
                }
            }
        }else{
            
            onGetCampaign(.GetCampaignError)
        }
    }
    
    
    
    
    /////////////////////////////////////// SHIP VALUES /////////////////////////////////////////////////
    
    /**
     Get Modification from the decision api
     
     @param key for associated to value to read
     
     @param defaultBool this value will be used when this key don't exist
     
     @param activate if ture, the sdk send automaticaly an activate event. if false you have to do it manualy
     
     @return Boolean value
     
     */
    @objc public func getModification(_ key:String, defaultBool:Bool, activate:Bool = false) -> Bool {
        
        // Check if disabled
        if disabledSdk{
            FSLogger.FSlog("The Sdk is disabled ... will return a default value", .Campaign)
            return defaultBool
        }
        
        if activate && self.campaigns != nil{
            // Activate
            self.service?.activateCampaignRelativetoKey(key,self.campaigns)
        }
        
        return context.readBooleanFromContext(key, defaultBool: defaultBool)
    }
    
    
    
    /**
     Get Modification from the decision api
     
     @param key for associated to value
     
     @param defaultString will be used when the key don't exist
     
     @param activate if ture, the sdk send automaticaly an activate event. if false you have to do it manualy
     
     @return String value
     
     */
    @objc public func getModification(_ key:String, defaultString:String, activate:Bool = false) -> String{
        
        if disabledSdk{
            FSLogger.FSlog("The Sdk is disabled ... will return a default value", .Campaign)
            return defaultString
        }
        
        
        if activate && self.campaigns != nil {
            
            self.service?.activateCampaignRelativetoKey(key,self.campaigns)
        }
        return context.readStringFromContext(key, defaultString: defaultString)
    }
    
    /**
     Get Modification from the decision api
     
     @param key for associated to value
     
     @param defaultDouble will be used when the key don't exist
     
     @param activate if ture, the sdk send automaticaly an activate event. if false you have to do it manualy
     
     @return Double value
     */
    @objc public func getModification(_ key:String, defaultDouble:Double, activate:Bool = false) -> Double{
        
        if disabledSdk{
            FSLogger.FSlog("The Sdk is disabled ... will return a default value", .Campaign)
            return defaultDouble
        }
        
        
        if activate && self.campaigns != nil{
            
            self.service?.activateCampaignRelativetoKey(key,self.campaigns)
        }
        return context.readDoubleFromContext(key, defaultDouble: defaultDouble)
    }
    
    /**
     Get Modification from the decision api
     
     @param key for associated to value
     
     @param defaulfloat will be used when the key don't exist
     
     @param activate if ture, the sdk send automaticaly an activate event. if false you have to do it manualy
     
     @return Float value
     */
    @objc public func getModification(_ key:String, defaulfloat:Float, activate:Bool = false) -> Float{
        
        
        if disabledSdk{
            FSLogger.FSlog("The Sdk is disabled ... will return a default value", .Campaign)
            return defaulfloat
        }
        
        
        if activate && self.campaigns != nil{
            
            self.service?.activateCampaignRelativetoKey(key,self.campaigns)
        }
        return context.readFloatFromContext(key, defaultFloat: defaulfloat)
    }
    
    
    
    /**
     Get Modification from the decision api
     
     @param key for associated to value to read
     
     @param defaultInt this value will be used when this key don't exist
     
     @param activate if ture, the sdk send automaticaly an activate event. if false you have to do it manualy
     
     @return Int value
     
     */
    @objc public func getModification(_ key:String, defaultInt:Int, activate:Bool = false) -> Int{
        
        
        if disabledSdk{
            FSLogger.FSlog("The Sdk is disabled ... will return a default value ", .Campaign)
            return defaultInt
        }
        
        if activate && self.campaigns != nil {
            
            self.service?.activateCampaignRelativetoKey(key,self.campaigns)
        }
        
        return context.readIntFromContext(key, defaultInt: defaultInt)
    }
    
    
    /**
     Get Modification from the decision api
     
     @param key for associated value to read
     
     @param defaultArray this value will be used when this key don't exist
     
     @param activate if ture, the sdk send automaticaly an activate event. if false you have to do it manualy
     
     @return Array [Any]
     
     */
    
    public func getModification(_ key:String, defaultArray:[Any], activate:Bool = false) ->[Any]{
        
        return self.context.readArrayFromContext(key, defaultArray: defaultArray)
        
    }
    
    
    /**
     Get Modification from the decision api
     
     @param key for associated value to read
     
     @param defaultJson this value will be used when this key don't exist
     
     @param activate if ture, the sdk send automaticaly an activate event. if false you have to do it manualy
     
     @return Dictionary<String,Any>, represent the json object
     
     */
    public func getModification(_ key:String, defaultJson:Dictionary<String,Any>, activate:Bool = false) ->Dictionary<String,Any>{
        
        return self.context.readJsonObjectFromContext(key, defaultDico: defaultJson)
        
    }
    
    
    
    //// Tempo
    
    
    /*
     Get modification info.  { “campaignId”: “xxxx”, “variationGroupId”: “xxxx“, “variationId”: “xxxx”}
     
     @param key for associated  modification
     
     @return { “campaignId”: “xxxx”, “variationGroupId”: “xxxx“, “variationId”: “xxxx”} or nil
     */
    @objc public func getModificationInfo(_ key:String) -> [String:String]? {
        
        
        if self.campaigns != nil {
            
            return self.campaigns.getRelativekeyModificationInfos(key)
        }
        
        FSLogger.FSlog(" Any campaign found, to get the information's modification key", .Campaign) /// See later for the logs
        return nil
    }
    
    
    
    
    /**
     Activate Modifications values
     
     @key key which identifies the modification
     
     */
    
    @objc public func activateModification(key:String){
        
        if disabledSdk{
            FSLogger.FSlog("The Sdk is disabled ... activate will not be sent", .Campaign)
            return
            
        }
        
        if self.campaigns != nil {
            
            self.service?.activateCampaignRelativetoKey(key,self.campaigns)
        }
    }
    
    
    /**
     Send Hit for tracking data
     
     @param event Event Object (Page, Transaction, Item, Event)
     
     */
    public func sendHit<T: FSTrackingProtocol>(_ event:T){
        
        if disabledSdk{
            FSLogger.FSlog("FlagShip Disabled.....The event will not be sent", .Campaign)
            return
        }
        self.service?.sendTracking(event)
    }
    
    
    
    
    
    
    
    /// For Objective C Project, use the functions below to send Events
    /// See https://developers.flagship.io/ios/#hit-tracking
    
    /**
     Send Transaction event
     
     @param transacEvent : Transaction event
     
     */
    
    @objc public func sendTransactionEvent(_ transacEvent:FSTransaction){
        
        if disabledSdk{
            FSLogger.FSlog("FlagShip Disabled.....The event Transaction will not be sent", .Campaign)
            return
        }
        self.service?.sendTracking(transacEvent)
    }
    
    
    /**
     Send Page event
     
     @param pageEvent : Page event
     
     */
    @objc public func sendPageEvent(_ pageEvent:FSPage){
        
        if disabledSdk{
            FSLogger.FSlog("FlagShip Disabled.....The event Page will not be sent", .Campaign)
            return
        }
        self.service?.sendTracking(pageEvent)
    }
    
    
    
    /**
     Send Item event
     
     @param itemEvent : Item event
     
     */
    
    @objc public func sendItemEvent(_ itemEvent:FSItem){
        
        if disabledSdk{
            FSLogger.FSlog("FlagShip Disabled.....The event Item will not be sent", .Campaign)
            return
        }
        self.service?.sendTracking(itemEvent)
    }
    
    
    /**
     Send event track
     
     @param eventTrack : track event
     
     */
    @objc public func sendEventTrack(_ eventTrack:FSEvent){
        
        if disabledSdk{
            FSLogger.FSlog("FlagShip Disabled.....The event Track will not be sent", .Campaign)
            return
        }
        self.service?.sendTracking(eventTrack)
    }
    
    
    
}

//
//  FlyerView.swift
//  Attnd
//
//  Created by Andrew Beers on 11/29/21.
//

import SwiftUI
import WebKit


struct WebView: UIViewRepresentable {
 
    var url: URL
 
    func makeUIView(context: Context) -> WKWebView {
        return WKWebView()
    }
 
    func updateUIView(_ webView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        webView.load(request)
    }
}

struct FlyerView: View {
    
    let flyer_url = "https://storage.googleapis.com/attnd-test/Copy_of_Art__Craft_Street_Fair_Flyer_-_Made_with_PosterMyWall_baf26.jpg?X-Goog-Algorithm=GOOG4-RSA-SHA256&X-Goog-Credential=attnd-742%40attnd-df28e.iam.gserviceaccount.com%2F20211201%2Fauto%2Fstorage%2Fgoog4_request&X-Goog-Date=20211201T035132Z&X-Goog-Expires=86400&X-Goog-SignedHeaders=host&X-Goog-Signature=503f4686f05ab8bd2cb7fbcec8f946dd8b455f923eb5bb50507a5a7197ddc020efff30b8e85114920946c1e03c058bcdc235004db9323a430577da6ac1d37e18150c5f2b0a57a8b1b9ab419d0340ce74eef1883e478fc72825b8f48b980d6a4129561fbf82bf697f4a0bbd1204caab3bfa9e17369a166248e3407f832f85affc84d4251392793260718e2cc6d064d931317be8211a60af63036890714a999b29652c4c9a331bea74e5468a85312dc22539ef6969ec2d03069edc6163ea7f46c91a03890cca856c2c1d746a481bb3222e0175e5db3f4d208d0429139f055bea3d6a86c511a7e93a21d0b48a9ab215eba0f1af70deca335565b27addaa886fa264"
    
    var body: some View {
        WebView(url: URL(string: flyer_url)!)
    }
}

struct FlyerView_Previews: PreviewProvider {
    static var previews: some View {
        FlyerView()
    }
}

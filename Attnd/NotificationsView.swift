//
//  NotificationsView.swift
//  Attnd
//
//  Created by Andrew Beers on 11/29/21.
//

import SwiftUI
import Foundation

struct Notification: Decodable, Identifiable {
    let id: Int
    let title: String
    let body: String
    let send_time: String
}


class NotificationManager: ObservableObject {
    @Published var notifications = [Notification]()
    
    init() {
        guard let url = URL(string: "https://attnd-web-test.herokuapp.com/events/1/notifications/") else {
            return
        }
        
        URLSession.shared.dataTask(with: url) {(data, _, _) in
            guard let data = data else {
                return
            }
            
            let notifications = try! JSONDecoder().decode([Notification].self, from: data)
            self.notifications = notifications
        }.resume()
    }
}


struct NotificationsView: View {
    @State var notificationManager = NotificationManager()
    var body: some View {
        List(notificationManager.notifications) { notification in
            VStack(alignment: .leading) {
                Text(notification.title)
                Text(notification.body)
            }
            
        }
    }
}

struct NotificationsView_Previews: PreviewProvider {
    static var previews: some View {
        NotificationsView()
    }
}

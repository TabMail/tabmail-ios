/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

//
//  TabMail-Bridging-Header.h
//  TabMail
//

#ifndef TabMail_Bridging_Header_h
#define TabMail_Bridging_Header_h

// sqlite-vec: register vec0 virtual table module on a specific connection (for GRDB prepareDatabase)
int tabmail_register_sqlite_vec_on_db(void *db);

#endif /* TabMail_Bridging_Header_h */

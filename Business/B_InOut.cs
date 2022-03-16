using System;
using System.Collections.Generic;
using Entities;
using DataAccess;

namespace Business
{
    public class B_InOut
    {
        public static List<InOutEntity> OutputList()
        {
            using (var db = new InventoryContext())
            {
                return db.InOuts.ToList();
            }
        }
        
        public static void CreateOutput(InOutEntity oOutput)
        {
            using (var db = new InventoryContext())
            {
                db.InOuts.Add(oOutput);
                db.SaveChanges();
            }
        }

        public static void UpdateOutput(InOutEntity oOutput)
        {
            using (var db = new InventoryContext())
            {
                db.InOuts.Update(oOutput);
                db.SaveChanges();
            }
        }
    }
}